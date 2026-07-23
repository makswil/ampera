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
import 'scans_manager_page.dart';
import 'widgets/capture_overlay.dart';

/// Entry widget for V1 guided capture.
///
/// Owns dependency wiring, the native ARKit preview view and the BLoC-driven
/// [CaptureOverlay]. The preview is intentionally dumb (just renders the native
/// camera/mesh); all decision logic lives in the BLoC, fed by the tracking
/// service's frame stream.
class CapturePage extends StatefulWidget {
  const CapturePage({super.key});

  /// Native platform-view id for the ARKit face preview (see Swift side).
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
  String? _bakeStatus; // e.g. ml-wb Kelvin / failure (shown under guidance)

  /// Paths of the last baked model (obj/mtl/png), for the share sheet.
  BakedTexture? _baked;

  /// One RGB still + projection per pose, grabbed as each pose completes.
  final Map<FacePose, StillCapture> _stills = <FacePose, StillCapture>{};
  int _lastCompletedCount = 0;

  /// Serializes the per-pose still grabs so the session can await them all
  /// (including the final pose's) before persisting.
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
    _debug.removeListener(_onDebugChanged);
    _debug.dispose();
    // Bloc.close() tears down the tracking subscription/session.
    unawaited(_bloc.close());
    unawaited(_trackingService.dispose());
    super.dispose();
  }

  void _openScanSettings() {
    unawaited(_showSettingsSheet(
      title: 'Scan settings',
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
            'Closer = more face pixels (sharper). '
            'Too close → clip / distortion on side poses.',
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
          _bakeStatus = null;
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
      _bakeStatus = _debug.mlWb ? 'ml-wb…' : null;
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
          _bakeStatus = mlWbNote == null
              ? timingLine
              : '$mlWbNote · $timingLine';
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _baking = false;
          _bakeStatus = 'Bake failed: $e';
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
    _bloc.add(const CaptureStopped());
    setState(() {
      _stills.clear();
      _stillChain = Future<void>.value();
      _lastCompletedCount = 0;
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
      child: BlocListener<CaptureBloc, CaptureState>(
        listenWhen: (CaptureState prev, CaptureState next) =>
            prev.status != next.status ||
            prev.completedPoses.length != next.completedPoses.length,
        listener: (BuildContext context, CaptureState state) {
          // Grab a still the moment a new pose is captured (head is held still);
          // chained so _finishSession can await the final one before saving.
          if (state.completedPoses.length > _lastCompletedCount) {
            final FacePose pose = state.completedPoses.last;
            _stillChain = _stillChain.then((_) => _grabStill(pose));
          }
          _lastCompletedCount = state.completedPoses.length;

          if (state.status == CaptureStatus.completed) {
            unawaited(_finishSession(state));
          } else if (state.status == CaptureStatus.capturing &&
              state.completedPoses.isEmpty &&
              (_stills.isNotEmpty || _didPersistCurrent)) {
            // Brand-new session started — clear only in-progress stills. Keep
            // `_lastSession` so Bake still works on the previous disk session
            // until this run is saved.
            setState(() {
              _stills.clear();
              _stillChain = Future<void>.value();
              _lastCompletedCount = 0;
              _didPersistCurrent = false;
            });
          }
        },
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              const UiKitView(viewType: CapturePage.previewViewType),
              BlocBuilder<CaptureBloc, CaptureState>(
                builder: (BuildContext context, CaptureState state) =>
                    CaptureOverlay(
                  state: state,
                  onStart: () => _bloc.add(const CaptureStarted()),
                  onBake: () => unawaited(_bakeTexture()),
                  canBake: _lastSession != null && _lastDir != null,
                  baking: _baking,
                  targetDistanceMeters: _debug.targetDistanceMeters,
                  statusLine: _saving
                      ? 'Saving…'
                      : _baking
                          ? (_bakeStatus ?? 'Baking texture…')
                          : _bakeStatus ??
                              ((_lastSession != null && _baked == null)
                  ? 'Session ready — adjust 🖌, then Bake'
                                  : (_baked != null)
                                      ? 'Baked — Share above, or Bake again'
                                      : null),
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
              // Action icons: cancel, share, bake settings (brush), scan settings.
              Positioned(
                top: 0,
                right: 0,
                child: SafeArea(
                  child: BlocBuilder<CaptureBloc, CaptureState>(
                    builder: (BuildContext context, CaptureState state) => Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (state.status == CaptureStatus.capturing)
                          IconButton(
                            tooltip: 'Cancel',
                            icon: const Icon(
                              Icons.close,
                              color: Colors.white70,
                              size: 24,
                            ),
                            onPressed: _cancelScan,
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
                        if (kShowDevMenu) ...<Widget>[
                          IconButton(
                            tooltip: 'Bake settings',
                            icon: const Icon(
                              Icons.brush,
                              color: Colors.white70,
                              size: 24,
                            ),
                            onPressed: _openBakeSettings,
                          ),
                          IconButton(
                            tooltip: 'Scan settings',
                            icon: const Icon(
                              Icons.settings,
                              color: Colors.white70,
                              size: 24,
                            ),
                            onPressed: _openScanSettings,
                          ),
                        ],
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
}
