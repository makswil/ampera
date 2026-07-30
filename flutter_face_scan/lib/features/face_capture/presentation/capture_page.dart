import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:path_provider/path_provider.dart';

import '../application/capture_bloc.dart';
import '../application/capture_event.dart';
import '../application/capture_state.dart';
import '../application/capture_status.dart';
import '../data/arkit_face_tracking_service.dart';
import '../data/bake/session_baker.dart';
import '../data/file_snapshot_repository.dart';
import '../data/session_folder_loader.dart';
import '../domain/constants/face_vertex_indices.dart';
import '../domain/entities/capture_session.dart';
import '../domain/entities/face_pose.dart';
import '../domain/entities/saved_session.dart';
import '../domain/entities/still_capture.dart';
import '../domain/logic/guided_pose_validator.dart';
import '../domain/logic/least_squares_symmetry_axis_extractor.dart';
import '../domain/services/symmetry_axis_extractor.dart';
import '../domain/value_objects/pose_tolerance.dart';
import 'debug/capture_debug_hud.dart';
import 'debug/debug_settings.dart';
import 'feedback/capture_feedback.dart';
import 'onboarding_store.dart';
import 'pose_guidance_copy.dart';
import 'scan_theme.dart';
import 'scans_manager_page.dart';
import 'widgets/capture_overlay.dart';
import 'widgets/scan_onboarding_sheet.dart';

/// Guided capture entry: wires ARKit preview, BLoC, and [CaptureOverlay].
class CapturePage extends StatefulWidget {
  const CapturePage({super.key});

  static const String previewViewType = 'flutter_face_scan/face_preview';

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  late final ArkitFaceTrackingService _trackingService;
  late final CaptureBloc _bloc;
  late final GuidedPoseValidator _poseValidator;
  final DebugSettings _debug = DebugSettings();

  bool _saving = false;
  /// True after the current capture run was written to disk (one-shot).
  bool _didPersistCurrent = false;

  /// Kept after a successful save so the texture can be re-baked (e.g. when the
  /// eyes toggle changes) without re-capturing.
  CaptureSession? _lastSession;
  Directory? _lastDir;
  bool _baking = false;
  // Bake timing / ml-wb notes go to console — not the guidance surface.

  /// Paths of the last baked model (obj/mtl/png), for the share sheet.
  BakedTexture? _baked;

  /// One RGB still + projection per pose, grabbed as each pose completes.
  final Map<FacePose, StillCapture> _stills = <FacePose, StillCapture>{};
  int _lastCompletedCount = 0;

  /// Banner after each pose (“Captured N of 4”).
  String? _captureBanner;
  Timer? _bannerTimer;

  /// Defers next-pose UI until the still handoff finishes.
  bool _awaitingStill = false;

  /// Cover over the platform view during TrueDepth handoff.
  /// Also used on the last pose (status already completed) so “All angles
  /// captured” only appears after the freeze fades — same real still path.
  Uint8List? _previewFreeze;
  bool _freezeOpaque = false;

  Future<void> _stillChain = Future<void>.value();

  Future<void> _grabStill(FacePose pose) async {
    final StillCapture? still = await _trackingService.captureStill(
      hiRes: _debug.hiResPhoto,
      lockAeAwb: _debug.lockAeAwb,
    );
    if (still != null && still.bytes.isNotEmpty) {
      _stills[pose] = still;
    }
  }

  Future<void> _capturePoseStill(FacePose pose) async {
    Uint8List? freeze;
    if (_debug.hiResPhoto) {
      freeze = await _trackingService.previewFreeze();
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _awaitingStill = true;
      _previewFreeze = freeze;
      _freezeOpaque = freeze != null;
    });
    _triggerPoseCapturedFeedback(_bloc.state.completedPoses.length);
    await _grabStill(pose);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) {
      return;
    }
    setState(() {
      _freezeOpaque = false;
      _awaitingStill = false;
    });
    if (_previewFreeze != null) {
      await Future<void>.delayed(const Duration(milliseconds: 340));
      if (mounted) {
        setState(() => _previewFreeze = null);
      }
    }
  }

  /// Waits for every still to be captured, then persists the session.
  Future<void> _finishSession(CaptureState state) async {
    await _stillChain;
    await _persist(state);
  }

  @override
  void initState() {
    super.initState();
    _trackingService = ArkitFaceTrackingService();
    const SymmetryAxisExtractor extractor = LeastSquaresSymmetryAxisExtractor();
    _poseValidator = GuidedPoseValidator(axisExtractor: extractor);
    _syncDistanceTolerance();
    // Don't auto-start: the user starts each scan from the Start button so the
    // preview + guidance don't run until asked.
    _bloc = CaptureBloc(
      trackingService: _trackingService,
      poseValidator: _poseValidator,
    );

    // Re-push the overlay config whenever a debug toggle changes.
    _debug.addListener(_onDebugChanged);
    _applyOverlay();
    unawaited(_loadNewestSession());
  }

  /// Restores the newest on-disk session so Bake works without a fresh scan.
  Future<void> _loadNewestSession() async {
    try {
      final Directory documents = await getApplicationDocumentsDirectory();
      final ({CaptureSession session, SavedSession saved})? loaded =
          await const SessionFolderLoader().loadNewest(documents);
      if (!mounted || loaded == null) {
        return;
      }
      // Don't clobber a session just captured in this run.
      if (_lastSession != null) {
        return;
      }
      setState(() {
        _lastSession = loaded.session;
        _lastDir = Directory(loaded.saved.directoryPath);
      });
    } on Object {
      // No saved session / unloadable — Bake stays hidden.
    }
  }

  void _onDebugChanged() {
    _syncDistanceTolerance();
    _applyOverlay();
    // Face-frame oval + slider label rebuild.
    if (mounted) {
      setState(() {});
    }
  }

  /// Pushes the debug slider's target distance into the live pose validator.
  void _syncDistanceTolerance() {
    _poseValidator.tolerance = PoseTolerance(
      targetDistanceMeters: _debug.targetDistanceMeters,
    );
  }

  /// Hands the Dart-owned axis index table to native (required for the 2D
  /// "facing camera" gate) and reflects the current mesh-overlay toggle.
  void _applyOverlay() {
    unawaited(
      _trackingService.setOverlay(
        showMesh: _debug.showMesh,
        axisIndices: FaceSymmetryAxis.ordered,
      ),
    );
  }

  @override
  void dispose() {
    _bannerTimer?.cancel();
    _debug.removeListener(_onDebugChanged);
    _debug.dispose();
    // Bloc.close() tears down the tracking subscription/session.
    unawaited(_bloc.close());
    unawaited(_trackingService.dispose());
    super.dispose();
  }

  Future<void> _handleStart() async {
    CaptureFeedback.reset();
    final bool seen = await OnboardingStore.hasSeen();
    if (!mounted) {
      return;
    }
    if (!seen) {
      await _trackingService.dismissPresented();
      if (!mounted) {
        return;
      }
      final bool? started = await showScanOnboardingSheet(
        context,
        onStart: () {
          unawaited(OnboardingStore.markSeen());
          _bloc.add(const CaptureStarted());
        },
      );
      if (started != true) {
        // User dismissed without starting — still mark seen so they aren't
        // blocked; they can reopen help via the `?` button.
        unawaited(OnboardingStore.markSeen());
      }
      return;
    }
    _bloc.add(const CaptureStarted());
  }

  void _showHowToScan() {
    unawaited(() async {
      await _trackingService.dismissPresented();
      if (!mounted) {
        return;
      }
      await showScanOnboardingSheet(
        context,
        onStart: () {},
        showStartButton: false,
      );
    }());
  }

  /// Settings sheet (distance, scans, dev toggles). Help is the `?` button.
  void _openSettings() {
    unawaited(_showSettingsSheet(
      title: 'Settings',
      buildChildren: () => <Widget>[
        ListTile(
          leading: const Icon(Icons.folder_outlined),
          title: const Text('Manage saved scans'),
          subtitle: const Text('List / delete session folders'),
          onTap: () {
            Navigator.of(context, rootNavigator: true).pop();
            unawaited(
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const ScansManagerPage(),
                ),
              ),
            );
          },
        ),
        const Divider(height: 1),
        ListTile(
          title: Text(
            'Face distance: '
            '${(_debug.targetDistanceMeters * 100).round()} cm',
          ),
          subtitle: const Text(
            'Closer fills the outline more. '
            'Too close can clip on side angles.',
          ),
        ),
        Slider(
          value: _debug.targetDistanceMeters,
          min: PoseTolerance.kMinTargetDistanceMeters,
          max: PoseTolerance.kMaxTargetDistanceMeters,
          divisions: 20,
          label: '${(_debug.targetDistanceMeters * 100).round()} cm',
          onChanged: (double v) => _debug.targetDistanceMeters = v,
        ),
        const Divider(height: 1),
        SwitchListTile(
          title: const Text('Calibration HUD'),
          value: _debug.showHud,
          onChanged: (bool v) => _debug.showHud = v,
        ),
        SwitchListTile(
          title: const Text('Face mesh overlay'),
          value: _debug.showMesh,
          onChanged: (bool v) => _debug.showMesh = v,
        ),
        SwitchListTile(
          title: const Text('Texture: AVCapture hi-res'),
          subtitle: const Text(
            'On = 7 MP photo per pose (sharper). '
            'Off = ARKit video (stable).',
          ),
          value: _debug.hiResPhoto,
          onChanged: (bool v) => _debug.hiResPhoto = v,
        ),
        SwitchListTile(
          title: const Text('Lock AE/AWB after first shot'),
          subtitle: Text(
            _debug.hiResPhoto
                ? 'On = reuse ISO/shutter/WB from the first hi-res pose '
                    '(usually frontal). Off = auto per pose.'
                : 'Enable AVCapture hi-res first.',
          ),
          value: _debug.lockAeAwb,
          onChanged:
              _debug.hiResPhoto ? (bool v) => _debug.lockAeAwb = v : null,
        ),
      ],
    ));
  }

  void _openBakeSettings() {
    unawaited(_showSettingsSheet(
      title: 'Bake settings',
      buildChildren: () => <Widget>[
        SwitchListTile(
          title: const Text('ml-wb white balance'),
          subtitle: const Text(
            'CoreML white-balance on pose stills before bake. '
            'Re-bake to apply.',
          ),
          value: _debug.mlWb,
          onChanged: (bool v) => _debug.mlWb = v,
        ),
        SwitchListTile(
          title: const Text('ml-wb: match frontal'),
          subtitle: Text(
            _debug.mlWb
                ? 'On = all poses → frontal Kelvin. '
                    'Off = all poses → default 5600 K.'
                : 'Enable ml-wb first.',
          ),
          value: _debug.mlWbMatchFrontal,
          onChanged:
              _debug.mlWb ? (bool v) => _debug.mlWbMatchFrontal = v : null,
        ),
        const Divider(height: 1),
        SwitchListTile(
          title: const Text('Fill eye/mouth holes'),
          subtitle: const Text('Off = leave ARKit holes in the model'),
          value: _debug.fillHoles,
          onChanged: (bool v) => _debug.fillHoles = v,
        ),
        SwitchListTile(
          title: const Text('Chin-up for lower face'),
          subtitle: const Text(
            'On = chin/jaw from the chin-up pose. '
            'Off = frontal only.',
          ),
          value: _debug.chinUpLowerFace,
          onChanged: (bool v) => _debug.chinUpLowerFace = v,
        ),
        SwitchListTile(
          title: const Text('View-dependent blend (n·v)'),
          subtitle: const Text(
            'On = pick the photo that saw each surface most head-on. '
            'Off = static region tables. Re-bake to apply.',
          ),
          value: _debug.viewDependent,
          onChanged: (bool v) => _debug.viewDependent = v,
        ),
        SwitchListTile(
          title: const Text('View: best pose only (sharper)'),
          subtitle: const Text(
            'On = single best photo per point (sharp, seams). '
            'Off = weighted blend (smooth). Only with view-dependent.',
          ),
          value: _debug.viewBestOnly,
          onChanged: _debug.viewDependent
              ? (bool v) => _debug.viewBestOnly = v
              : null,
        ),
        SwitchListTile(
          title: const Text('Dart colour match (poseGain)'),
          subtitle: Text(
            _debug.viewDependent
                ? 'On = match side poses to frontal RGB over overlap. '
                    'Independent of ml-wb — try combinations.'
                : 'Enable view-dependent first.',
          ),
          value: _debug.dartColorGain,
          onChanged: _debug.viewDependent
              ? (bool v) => _debug.dartColorGain = v
              : null,
        ),
        SwitchListTile(
          title: const Text('Normal map (TrueDepth mesh)'),
          subtitle: const Text(
            'On = bake *_n.png (object-space). Assign as Normal Map in the '
            'viewer — not as Bump/Height (that washes the face white). Re-bake.',
          ),
          value: _debug.bakeNormalMap,
          onChanged: (bool v) => _debug.bakeNormalMap = v,
        ),
        const Divider(height: 1),
        ListTile(
          leading: _baking
              ? const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.brush),
          title: Text(_baking ? 'Baking…' : 'Bake now'),
          subtitle: Text(
            _lastSession == null
                ? 'No session loaded'
                : (_debug.mlWb
                    ? (_debug.mlWbMatchFrontal
                        ? 'ml-wb → frontal Kelvin'
                        : 'ml-wb → 5600 K')
                    : 'ml-wb off'),
          ),
          enabled: !_baking && _lastSession != null,
          onTap: _baking || _lastSession == null
              ? null
              : () {
                  Navigator.of(context, rootNavigator: true).pop();
                  unawaited(_bakeTexture());
                },
        ),
      ],
    ));
  }

  Future<void> _showSettingsSheet({
    required String title,
    required List<Widget> Function() buildChildren,
  }) async {
    // Share sheet can leave a native modal that blocks Flutter sheets.
    await _trackingService.dismissPresented();
    if (!mounted) {
      return;
    }
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useRootNavigator: true,
      builder: (BuildContext sheetContext) => ListenableBuilder(
        listenable: _debug,
        builder: (BuildContext context, Widget? _) {
          final double maxH = MediaQuery.sizeOf(context).height * 0.85;
          return SafeArea(
            child: ConstrainedBox(
              constraints: BoxConstraints(maxHeight: maxH),
              child: ListView(
                shrinkWrap: true,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                    child: Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                  // Rebuild switches on every notifyListeners — a fixed children
                  // list would freeze SwitchListTile.value at open-time.
                  ...buildChildren(),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  /// Persists the captured snapshots once the session completes (one-shot).
  Future<void> _persist(CaptureState state) async {
    if (_saving || _didPersistCurrent || state.snapshots.isEmpty) {
      return;
    }
    setState(() => _saving = true);
    try {
      final Directory documents = await getApplicationDocumentsDirectory();
      final FileSnapshotRepository repository = FileSnapshotRepository(
        rootDirectory: documents,
      );
      final CaptureSession session = CaptureSession(
        id: 'session_${DateTime.now().millisecondsSinceEpoch}',
        createdAt: DateTime.now(),
        snapshots: state.snapshots,
        stills: Map<FacePose, StillCapture>.of(_stills),
      );
      final SavedSession saved = await repository.save(session);
      _lastSession = session;
      _lastDir = Directory(saved.directoryPath);
      if (mounted) {
        setState(() {
          _saving = false;
          _didPersistCurrent = true;
          _baked = null;
        });
      }
      // No auto-bake: user tweaks bake settings first, then taps Bake.
    } on Object {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// Bakes (or re-bakes) the last saved session's texture with the current bake
  /// settings. No-op if nothing is saved yet or a bake is already running.
  Future<void> _bakeTexture() async {
    final CaptureSession? session = _lastSession;
    final Directory? dir = _lastDir;
    if (session == null || dir == null || _baking) {
      return;
    }
    setState(() {
      _baking = true;
    });
    try {
      String? mlWbNote;
      CaptureSession bakeSession = session;
      final Stopwatch wall = Stopwatch()..start();
      int? mlWbMs;
      if (_debug.mlWb) {
        final Stopwatch mlSw = Stopwatch()..start();
        final ({CaptureSession session, String note}) applied =
            await _applyMlWb(session);
        mlWbMs = mlSw.elapsedMilliseconds;
        bakeSession = applied.session;
        mlWbNote = applied.note;
      }
      // Dart poseGain is its own toggle (combinable with ml-wb).
      final Stopwatch bakeSw = Stopwatch()..start();
      final BakedTexture? baked = await const SessionTextureBaker().bake(
        session: bakeSession,
        directory: dir,
        fillHoles: _debug.fillHoles,
        textureSize: 0, // 0 = Original (source photo resolution)
        useChinUp: _debug.chinUpLowerFace,
        viewDependent: _debug.viewDependent,
        viewBlend: !_debug.viewBestOnly,
        colorMatch: _debug.viewDependent && _debug.dartColorGain,
        colorMatchNeutral: false,
        bakeNormalMap: _debug.bakeNormalMap,
      );
      final int bakeMs = bakeSw.elapsedMilliseconds;
      wall.stop();
      final String bakeTiming = baked?.timingSummary ?? 'bake ${bakeMs}ms';
      final String timingLine = mlWbMs == null
          ? '$bakeTiming · wall ${wall.elapsedMilliseconds}ms'
          : 'ml-wb ${mlWbMs}ms · $bakeTiming · wall ${wall.elapsedMilliseconds}ms';
      // ignore: avoid_print
      print('[face_scan] $timingLine${mlWbNote != null ? ' | $mlWbNote' : ''}');
      if (mounted) {
        setState(() {
          _baking = false;
          _baked = baked;
        });
      }
    } on Object catch (e) {
      // ignore: avoid_print
      print('[face_scan] Bake failed: $e');
      if (mounted) {
        setState(() {
          _baking = false;
        });
      }
    }
  }

  /// Runs on-device ml-wb over every pose still. Frontal is always first so
  /// `matchFrontal` can use it as the shared Kelvin target.
  Future<({CaptureSession session, String note})> _applyMlWb(
    CaptureSession session,
  ) async {
    final List<FacePose> order = <FacePose>[
      FacePose.frontal,
      for (final FacePose p in FacePose.captureSequence)
        if (p != FacePose.frontal && session.stills.containsKey(p)) p,
    ];
    final List<FacePose> present = <FacePose>[
      for (final FacePose p in order)
        if (session.stills[p] != null) p,
    ];
    if (present.isEmpty) {
      return (session: session, note: 'ml-wb: no stills');
    }
    final List<Uint8List> inputs = <Uint8List>[
      for (final FacePose p in present) session.stills[p]!.bytes,
    ];
    final WhiteBalanceResult? result =
        await _trackingService.correctWhiteBalance(
      jpegs: inputs,
      matchFrontal: _debug.mlWbMatchFrontal,
      targetKelvin: 5600,
    );
    if (result == null || !result.ok || result.jpegs.length != present.length) {
      return (
        session: session,
        note: 'ml-wb FAILED (${result?.error ?? 'no response'}) — raw stills'
            '${result?.timingSummary != null ? ' · ${result!.timingSummary}' : ''}',
      );
    }
    final Map<FacePose, StillCapture> stills =
        Map<FacePose, StillCapture>.of(session.stills);
    for (int i = 0; i < present.length; i++) {
      final StillCapture old = stills[present[i]]!;
      stills[present[i]] = StillCapture(
        bytes: result.jpegs[i],
        width: old.width,
        height: old.height,
        viewMatrix: old.viewMatrix,
        projectionMatrix: old.projectionMatrix,
        faceTransform: old.faceTransform,
      );
    }
    final String mode =
        _debug.mlWbMatchFrontal ? 'frontal' : '5600 K';
    final String timing = result.timingSummary != null
        ? ' · ${result.timingSummary}'
        : '';
    return (
      session: CaptureSession(
        id: session.id,
        createdAt: session.createdAt,
        snapshots: session.snapshots,
        stills: stills,
      ),
      note: 'ml-wb OK → ${result.targetKelvin.round()} K ($mode)$timing',
    );
  }

  /// Cancels the running scan back to idle and discards the partial captures.
  void _cancelScan() {
    CaptureFeedback.cancelled();
    CaptureFeedback.reset();
    _bannerTimer?.cancel();
    _bloc.add(const CaptureStopped());
    setState(() {
      _stills.clear();
      _stillChain = Future<void>.value();
      _lastCompletedCount = 0;
      _captureBanner = null;
      _awaitingStill = false;
      _previewFreeze = null;
      _freezeOpaque = false;
    });
  }

  void _triggerPoseCapturedFeedback(int capturedCount) {
    CaptureFeedback.poseCaptured();
    _bannerTimer?.cancel();
    setState(() {
      _captureBanner = PoseGuidanceCopy.capturedProgress(
        capturedCount,
        FacePose.captureSequence.length,
      );
    });
    _bannerTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) {
        setState(() => _captureBanner = null);
      }
    });
  }

  /// Opens the native iOS share sheet with the baked model files (obj+mtl+png).
  Future<void> _shareModel() async {
    final BakedTexture? baked = _baked;
    if (baked == null) {
      return;
    }
    final List<String> paths = <String>[
      baked.objPath,
      baked.mtlPath,
      baked.texturePath,
      if (baked.normalPath != null) baked.normalPath!,
    ];
    await _trackingService.shareFiles(paths);
  }

  @override
  Widget build(BuildContext context) {
    return BlocProvider<CaptureBloc>.value(
      value: _bloc,
      child: MultiBlocListener(
        listeners: <BlocListener<CaptureBloc, CaptureState>>[
          BlocListener<CaptureBloc, CaptureState>(
            listenWhen: (CaptureState prev, CaptureState next) =>
                prev.status != next.status ||
                prev.completedPoses.length != next.completedPoses.length,
            listener: (BuildContext context, CaptureState state) {
              if (state.completedPoses.length > _lastCompletedCount) {
                final FacePose pose = state.completedPoses.last;
                // Sync flag before this frame builds — otherwise completed copy
                // flashes over the freeze on the last pose.
                setState(() => _awaitingStill = true);
                _stillChain = _stillChain.then((_) => _capturePoseStill(pose));
              }
              _lastCompletedCount = state.completedPoses.length;

              if (state.status == CaptureStatus.completed) {
                CaptureFeedback.scanCompleted();
                unawaited(_finishSession(state));
              } else if (state.status == CaptureStatus.capturing &&
                  state.completedPoses.isEmpty &&
                  (_stills.isNotEmpty || _didPersistCurrent)) {
                CaptureFeedback.reset();
                setState(() {
                  _stills.clear();
                  _stillChain = Future<void>.value();
                  _lastCompletedCount = 0;
                  _didPersistCurrent = false;
                  _captureBanner = null;
                  _awaitingStill = false;
                  _previewFreeze = null;
                  _freezeOpaque = false;
                });
              } else if (state.status == CaptureStatus.idle) {
                CaptureFeedback.reset();
                if (_awaitingStill || _previewFreeze != null) {
                  setState(() {
                    _awaitingStill = false;
                    _previewFreeze = null;
                    _freezeOpaque = false;
                  });
                }
              }
            },
          ),
          BlocListener<CaptureBloc, CaptureState>(
            listenWhen: (CaptureState prev, CaptureState next) {
              final bool prevOn =
                  prev.lastValidation?.isOnTarget ?? false;
              final bool nextOn =
                  next.lastValidation?.isOnTarget ?? false;
              return prevOn != nextOn || prev.status != next.status;
            },
            listener: (BuildContext context, CaptureState state) {
              if (state.status == CaptureStatus.capturing) {
                CaptureFeedback.onTargetChanged(
                  onTarget: state.lastValidation?.isOnTarget ?? false,
                );
              }
            },
          ),
        ],
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const UiKitView(viewType: CapturePage.previewViewType),
              if (_previewFreeze != null)
                IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _freezeOpaque ? 1 : 0,
                    duration: const Duration(milliseconds: 320),
                    curve: Curves.easeOut,
                    child: Image.memory(
                      _previewFreeze!,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      gaplessPlayback: true,
                      filterQuality: FilterQuality.low,
                    ),
                  ),
                ),
              BlocBuilder<CaptureBloc, CaptureState>(
                builder: (BuildContext context, CaptureState state) =>
                    CaptureOverlay(
                  state: state,
                  onStart: () => unawaited(_handleStart()),
                  onRetake: () => unawaited(_handleStart()),
                  onOpenSettings: () =>
                      unawaited(_trackingService.openAppSettings()),
                  targetDistanceMeters: _debug.targetDistanceMeters,
                  captureBanner: _captureBanner,
                  deferPoseGuidance: _awaitingStill,
                  statusLine: _consumerStatusLine(),
                ),
              ),
              // Calibration HUD — visibility is a runtime debug toggle.
              ListenableBuilder(
                listenable: _debug,
                builder: (BuildContext context, Widget? _) => _debug.showHud
                    ? BlocBuilder<CaptureBloc, CaptureState>(
                        builder: (BuildContext context, CaptureState state) =>
                            CaptureDebugHud(
                          state: state,
                          hiRes: _trackingService.hiResCapture,
                          srcRes: _trackingService.captureWidth > 0
                              ? '${_trackingService.captureWidth}'
                                  'x${_trackingService.captureHeight}'
                              : null,
                          photoRes: _trackingService.photoWidth > 0
                              ? '${_trackingService.photoWidth}'
                                  'x${_trackingService.photoHeight}'
                              : null,
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              Positioned(
                top: 0,
                right: 0,
                child: SafeArea(
                  child: BlocBuilder<CaptureBloc, CaptureState>(
                    builder: (BuildContext context, CaptureState state) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (state.status == CaptureStatus.capturing)
                          Semantics(
                            button: true,
                            label: 'Cancel scan',
                            child: IconButton(
                              tooltip: 'Cancel',
                              icon: const Icon(
                                Icons.close,
                                color: Colors.white70,
                                size: 24,
                              ),
                              onPressed: _cancelScan,
                            ),
                          ),
                        if (_baked != null)
                          IconButton(
                            tooltip: 'Share model',
                            icon: const Icon(
                              Icons.ios_share,
                              color: Colors.white70,
                              size: 24,
                            ),
                            onPressed: () => unawaited(_shareModel()),
                          ),
                        IconButton(
                          tooltip: 'Bake settings',
                          icon: Icon(
                            Icons.brush,
                            color: _baking ? ScanTheme.accent : Colors.white70,
                            size: 24,
                          ),
                          onPressed: _openBakeSettings,
                        ),
                        Semantics(
                          button: true,
                          label: 'How to scan',
                          child: IconButton(
                            tooltip: 'How to scan',
                            icon: const Icon(
                              Icons.help_outline,
                              color: Colors.white70,
                              size: 24,
                            ),
                            onPressed: _showHowToScan,
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: 'Settings',
                          child: IconButton(
                            tooltip: 'Settings',
                            icon: const Icon(
                              Icons.settings,
                              color: Colors.white70,
                              size: 24,
                            ),
                            onPressed: _openSettings,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String? _consumerStatusLine() {
    if (_saving) {
      return 'Saving…';
    }
    if (_didPersistCurrent && !_baking) {
      return 'Saved on this device';
    }
    // Bake / ml-wb timing stays in the bake sheet + console — not on the
    // consumer guidance surface.
    return null;
  }
}
