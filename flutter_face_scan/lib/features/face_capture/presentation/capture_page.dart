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
import '../application/session_white_balance.dart';
import '../data/arkit_face_tracking_service.dart';
import '../data/bake/session_baker.dart';
import '../data/file_snapshot_repository.dart';
import '../data/rear_face_tracking_service.dart';
import '../data/session_folder_loader.dart';
import '../data/tracking_backend_router.dart';
import '../domain/constants/capture_defaults.dart';
import '../domain/constants/face_vertex_indices.dart';
import '../domain/entities/capture_actor_mode.dart';
import '../domain/entities/capture_session.dart';
import '../domain/entities/capture_snapshot.dart';
import '../domain/entities/expression_mode.dart';
import '../domain/entities/face_pose.dart';
import '../domain/entities/saved_session.dart';
import '../domain/entities/still_capture.dart';
import '../domain/logic/expression_aware_pose_validator.dart';
import '../domain/logic/guided_pose_validator.dart';
import '../domain/logic/least_squares_symmetry_axis_extractor.dart';
import '../domain/services/symmetry_axis_extractor.dart';
import '../domain/value_objects/pose_tolerance.dart';
import 'debug/capture_debug_hud.dart';
import 'debug/debug_settings.dart';
import 'face_scan_log.dart';
import 'feedback/capture_feedback.dart';
import 'onboarding_store.dart';
import 'pose_guidance_copy.dart';
import 'scan_theme.dart';
import 'scans_manager_page.dart';
import 'theme_settings.dart';
import 'widgets/capture_overlay.dart';
import 'widgets/scan_onboarding_sheet.dart';

/// Guided capture entry: wires ARKit preview, BLoC, and [CaptureOverlay].
class CapturePage extends StatefulWidget {
  const CapturePage({required this.themeSettings, super.key});

  final ThemeSettings themeSettings;

  static const String previewViewType = 'flutter_face_scan/face_preview';

  @override
  State<CapturePage> createState() => _CapturePageState();
}

class _CapturePageState extends State<CapturePage> {
  late final TrackingBackendRouter _trackingService;
  late final CaptureBloc _bloc;
  late final GuidedPoseValidator _guidedValidator;
  late final ExpressionAwarePoseValidator _poseValidator;
  final DebugSettings _debug = DebugSettings();
  ThemeSettings get _theme => widget.themeSettings;

  /// Expression chosen in the idle picker; applied on the next Start.
  ExpressionMode _selectedExpression = ExpressionMode.neutral;

  bool get _wantsRearPhoto =>
      _debug.actorMode == CaptureActorMode.practitioner &&
      _debug.clinicianCamera == ClinicianCamera.rear;

  bool get _wantsRearVideo =>
      _wantsRearPhoto && _debug.rearCaptureKind == RearCaptureKind.video;

  /// Clinician · Mesh now · Rear → front mesh pass, then rear photo/video.
  bool get _wantsSequentialMeshThenRear =>
      _wantsRearPhoto &&
      _debug.practitionerFlow == PractitionerFlow.meshThenPhotos;

  /// Clinician · Prior mesh → photo-only; mesh loaded from a saved session.
  bool get _wantsPriorMeshPhotoOnly =>
      _debug.actorMode == CaptureActorMode.practitioner &&
      _debug.practitionerFlow == PractitionerFlow.reuseMeshRef;

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

  /// Active sequential pass; null for single-pass runs / idle.
  CapturePass? _sequentialPass;

  /// When false, [UiKitView] is removed so iOS text fields (e.g. rename) work.
  /// Platform views under a pushed route break TextField caret/input on iOS.
  bool _platformPreviewVisible = true;

  /// Mesh-pass snapshots stashed before the rear photo pass restarts the bloc.
  List<CaptureSnapshot>? _meshSnapshots;

  /// Front bake stills from the mesh pass (paired with [_meshSnapshots]).
  final Map<FacePose, StillCapture> _meshStills = <FacePose, StillCapture>{};

  /// One RGB still + projection per pose, grabbed as each pose completes.
  /// During the photo pass these are rear enrichment frames.
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
    final bool meshPassHiRes = _sequentialPass == CapturePass.mesh;
    final StillCapture? still = await _trackingService.captureStill(
      hiRes: _debug.hiResPhoto || _trackingService.isRear || meshPassHiRes,
      lockAeAwb: _debug.lockAeAwb,
      preferHarvestedVideoFrame: _wantsRearVideo &&
          (_sequentialPass == CapturePass.photo || _meshSnapshots != null),
    );
    if (still != null && still.bytes.isNotEmpty) {
      _stills[pose] = still;
    }
  }

  Future<void> _capturePoseStill(FacePose pose) async {
    Uint8List? freeze;
    if (_debug.hiResPhoto || _trackingService.isRear) {
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
    final int capturedCount = _bloc.state.completedPoses.length;
    await _grabStill(pose);
    await Future<void>.delayed(const Duration(milliseconds: 120));
    if (!mounted) {
      return;
    }
    // Cue with freeze dissolve — not at freeze start (felt like “done” while still frozen).
    setState(() {
      _freezeOpaque = false;
      _awaitingStill = false;
    });
    _triggerPoseCapturedFeedback(capturedCount);
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
    _clearSequentialStash();
    await _syncIdlePreview();
  }

  /// After mesh pass: keep front mesh+stills, switch to rear, restart poses.
  Future<void> _handoffMeshToPhotoPass(CaptureState meshState) async {
    await _stillChain;
    if (!mounted || _sequentialPass != CapturePass.mesh) {
      return;
    }
    _meshSnapshots = List<CaptureSnapshot>.of(meshState.snapshots);
    _meshStills
      ..clear()
      ..addAll(_stills);
    setState(() {
      _stills.clear();
      _stillChain = Future<void>.value();
      _lastCompletedCount = 0;
      _sequentialPass = CapturePass.photo;
      _captureBanner = 'Mesh done — rear photos';
      _awaitingStill = true;
      _previewFreeze = null;
      _freezeOpaque = false;
    });
    _bannerTimer?.cancel();
    _bannerTimer = Timer(const Duration(milliseconds: 2200), () {
      if (mounted) {
        setState(() => _captureBanner = null);
      }
    });
    try {
      await _trackingService.select(TrackingBackend.rear);
      if (mounted) {
        setState(() {});
      }
      await _trackingService.setRearPreferVideo(_wantsRearVideo);
      if (_wantsRearVideo) {
        await _trackingService.beginRearHarvest(
          lockAeAwb: _debug.lockAeAwb,
        );
      }
      if (!mounted) {
        return;
      }
      setState(() => _awaitingStill = false);
      _bloc.add(
        CaptureStarted(
          expressionMode: ExpressionMode.neutral,
          actorMode: CaptureActorMode.practitioner,
          practitionerFlow: _debug.practitionerFlow,
          meshMotion: _debug.meshMotion,
          clinicianCamera: ClinicianCamera.rear,
          rearCaptureKind: _debug.rearCaptureKind,
        ),
      );
    } on Object catch (error) {
      if (!mounted) {
        return;
      }
      _clearSequentialStash();
      _bloc.add(CaptureFailed('Photo pass failed: $error'));
    }
  }

  void _clearSequentialStash() {
    _sequentialPass = null;
    _meshSnapshots = null;
    _meshStills.clear();
  }

  TrackingBackend get _wantedIdleBackend =>
      _wantsRearPhoto ? TrackingBackend.rear : TrackingBackend.front;

  /// Idle preview matches settings (front TrueDepth vs rear wide).
  Future<void> _syncIdlePreview() async {
    final TrackingBackend wanted = _wantedIdleBackend;
    try {
      if (_trackingService.backend != wanted) {
        await _trackingService.select(wanted);
        if (mounted) {
          setState(() {});
        }
      }
      // Idle stays on photo preset; 4K video harvest engages only on Start.
      if (wanted == TrackingBackend.rear) {
        await _trackingService.setRearPreferVideo(false);
      }
      await _trackingService.start();
    } on Object {
      // Preview may recover on next Start / settings change.
    }
  }

  @override
  void initState() {
    super.initState();
    _trackingService = TrackingBackendRouter(
      front: ArkitFaceTrackingService(),
      rear: RearFaceTrackingService(),
    );
    const SymmetryAxisExtractor extractor = LeastSquaresSymmetryAxisExtractor();
    _guidedValidator = GuidedPoseValidator(axisExtractor: extractor);
    _poseValidator = ExpressionAwarePoseValidator(inner: _guidedValidator);
    _bloc = CaptureBloc(
      trackingService: _trackingService,
      poseValidator: _poseValidator,
    );
    _syncDistanceTolerance();

    // Live preview immediately; Start only begins guided capture / saving.
    unawaited(_syncIdlePreview());

    // Re-push the overlay config whenever a debug toggle changes.
    _debug.addListener(_onDebugChanged);
    _applyOverlay();
    unawaited(_loadNewestSession());
  }

  Future<void> _prepareBackendForStart() async {
    // Sequential mesh→rear always begins on front TrueDepth.
    final TrackingBackend wanted = _wantsSequentialMeshThenRear
        ? TrackingBackend.front
        : _wantedIdleBackend;
    if (_trackingService.backend != wanted) {
      await _trackingService.select(wanted);
      if (mounted) {
        setState(() {});
      }
    }
    if (wanted == TrackingBackend.rear) {
      // Idle preview uses photo preset; video scan switches to 4K harvest mode.
      await _trackingService.setRearPreferVideo(_wantsRearVideo);
      if (_wantsRearVideo) {
        await _trackingService.beginRearHarvest(
          lockAeAwb: _debug.lockAeAwb,
        );
      }
    } else {
      await _trackingService.setRearPreferVideo(false);
    }
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
    final CaptureStatus status = _bloc.state.status;
    // Any settings tweak leaves the completed/"Scan again" surface and aborts
    // an in-flight scan so the next action is a clean Start.
    if (status == CaptureStatus.capturing ||
        status == CaptureStatus.completed ||
        status == CaptureStatus.error) {
      _resetCaptureUiToIdle(playCancelFeedback: status == CaptureStatus.capturing);
    }
    // Camera switch only when Front/Rear (or operator) selection changed —
    // not on every distance/HUD slider tick.
    if (_trackingService.backend != _wantedIdleBackend) {
      unawaited(_syncIdlePreview());
    }
    if (mounted) {
      setState(() {});
    }
  }

  /// Pushes stability profile + face distance into validator and bloc hold timing.
  void _syncDistanceTolerance() {
    final PoseTolerance tolerance = PoseTolerance.forProfile(
      _debug.stabilityProfile,
      targetDistanceMeters: _debug.targetDistanceMeters,
    );
    _guidedValidator.tolerance = tolerance;
    _bloc.tolerance = tolerance;
  }

  /// Hands the Dart-owned axis index table to native (required for the 2D
  /// "facing camera" gate) and applies the Settings mesh-overlay toggle.
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
    if (_wantsPriorMeshPhotoOnly) {
      final bool ready = await _preparePriorMeshRef();
      if (!ready || !mounted) {
        return;
      }
    }
    await _prepareBackendForStart();
    if (!mounted) {
      return;
    }
    if (!_wantsPriorMeshPhotoOnly) {
      _clearSequentialStash();
    }
    if (_wantsSequentialMeshThenRear) {
      _sequentialPass = CapturePass.mesh;
    }
    // Rear Vision has no blendshapes — smile gate would block forever.
    // Mesh pass of a sequential run uses front TrueDepth (smile OK).
    final bool photoOnlyPass =
        _sequentialPass == CapturePass.photo ||
        (_wantsRearPhoto && _sequentialPass != CapturePass.mesh);
    final ExpressionMode expression =
        photoOnlyPass ? ExpressionMode.neutral : _selectedExpression;
    // Mesh pass guidance uses front camera semantics even when photos are rear.
    final ClinicianCamera startCamera = _sequentialPass == CapturePass.mesh
        ? ClinicianCamera.front
        : _debug.clinicianCamera;
    final CaptureStarted start = CaptureStarted(
      expressionMode: expression,
      actorMode: _debug.actorMode,
      practitionerFlow: _debug.practitionerFlow,
      meshMotion: _debug.meshMotion,
      clinicianCamera: startCamera,
      rearCaptureKind: _debug.rearCaptureKind,
    );
    if (!seen) {
      await _trackingService.dismissPresented();
      if (!mounted) {
        return;
      }
      final bool? started = await showScanOnboardingSheet(
        context,
        actorMode: guidanceActorMode(
          actorMode: _debug.actorMode,
          practitionerFlow: _debug.practitionerFlow,
          meshMotion: _debug.meshMotion,
          clinicianCamera: _debug.clinicianCamera,
        ),
        onStart: () {
          unawaited(OnboardingStore.markSeen());
          _bloc.add(start);
        },
      );
      if (started != true) {
        // User dismissed without starting — still mark seen so they aren't
        // blocked; they can reopen help via the `?` button.
        unawaited(OnboardingStore.markSeen());
      }
      return;
    }
    _bloc.add(start);
  }

  void _showHowToScan() {
    unawaited(() async {
      await _trackingService.dismissPresented();
      if (!mounted) {
        return;
      }
      await showScanOnboardingSheet(
        context,
        actorMode: guidanceActorMode(
          actorMode: _debug.actorMode,
          practitionerFlow: _debug.practitionerFlow,
          meshMotion: _debug.meshMotion,
          clinicianCamera: _debug.clinicianCamera,
        ),
        onStart: () {},
        showStartButton: false,
      );
    }());
  }

  Future<void> _openScansManager() async {
    await _trackingService.dismissPresented();
    if (!mounted) {
      return;
    }
    setState(() => _platformPreviewVisible = false);
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ScansManagerPage(appRole: _debug.appRole),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _platformPreviewVisible = true);
      }
    }
  }

  /// Loads a bakeable prior mesh into the sequential stash for a photo-only run.
  Future<bool> _preparePriorMeshRef() async {
    final String? id = _debug.meshRefSessionId;
    if (id == null || id.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Choose a prior mesh scan in Settings')),
        );
      }
      return false;
    }
    try {
      final Directory documents = await getApplicationDocumentsDirectory();
      final ({CaptureSession session, SavedSession saved})? loaded =
          await const SessionFolderLoader().loadById(documents, id);
      if (!mounted) {
        return false;
      }
      if (loaded == null || !loaded.session.hasBakeableMesh) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Prior mesh scan has no bakeable mesh')),
        );
        return false;
      }
      _clearSequentialStash();
      _meshSnapshots = List<CaptureSnapshot>.of(loaded.session.snapshots);
      _meshStills
        ..clear()
        ..addAll(loaded.session.stills);
      _sequentialPass = CapturePass.photo;
      return true;
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not load prior mesh scan')),
        );
      }
      return false;
    }
  }

  Future<void> _pickPriorMeshScan() async {
    await _trackingService.dismissPresented();
    if (!mounted) {
      return;
    }
    setState(() => _platformPreviewVisible = false);
    String? id;
    try {
      id = await Navigator.of(context).push<String>(
        MaterialPageRoute<String>(
          builder: (_) => const ScansManagerPage(pickMode: true),
        ),
      );
    } finally {
      if (mounted) {
        setState(() => _platformPreviewVisible = true);
      }
    }
    if (id != null) {
      _debug.meshRefSessionId = id;
    }
    unawaited(_syncIdlePreview());
  }

  /// Settings sheet (appearance, distance, dev toggles). Help is `?`.
  void _openSettings() {
    if (_bloc.state.status == CaptureStatus.capturing) {
      _resetCaptureUiToIdle(playCancelFeedback: true);
      unawaited(_syncIdlePreview());
    }
    unawaited(_openSettingsPage(
      title: 'Settings',
      buildChildren: () {
        final bool dark = _theme.isDark(
          MediaQuery.platformBrightnessOf(context),
        );
        return <Widget>[
          ListTile(
            title: const Text('Dark mode'),
            subtitle: _theme.mode == ThemeMode.system
                ? const Text('Following system')
                : null,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Icon(
                  Icons.wb_sunny_outlined,
                  size: 20,
                  color: dark
                      ? Theme.of(context).disabledColor
                      : ScanTheme.accent,
                ),
                Switch(
                  value: dark,
                  onChanged: _theme.setDark,
                ),
                Icon(
                  Icons.dark_mode_outlined,
                  size: 20,
                  color: dark
                      ? ScanTheme.accent
                      : Theme.of(context).disabledColor,
                ),
              ],
            ),
            onTap: () => _theme.setDark(!dark),
          ),
          const Divider(height: 1),
          ListTile(
            title: const Text('Role'),
            trailing: _SettingsDropdown<AppRole>(
              values: AppRole.values,
              selected: _debug.appRole,
              labelOf: (AppRole r) => r.label,
              onChanged: (AppRole r) => _debug.appRole = r,
            ),
          ),
          if (_debug.isDev)
            ListTile(
              title: const Text('Scan operator'),
              trailing: _SettingsSegmented<CaptureActorMode>(
                values: CaptureActorMode.values,
                selected: _debug.actorMode,
                labelOf: (CaptureActorMode m) => m.label,
                onChanged: (CaptureActorMode m) => _debug.actorMode = m,
              ),
            ),
          if (_debug.actorMode == CaptureActorMode.practitioner) ...<Widget>[
            ListTile(
              title: const Text('Mesh source'),
              trailing: _SettingsSegmented<PractitionerFlow>(
                values: PractitionerFlow.values,
                selected: _debug.practitionerFlow,
                labelOf: (PractitionerFlow f) => f.label,
                onChanged: (PractitionerFlow f) => _debug.practitionerFlow = f,
              ),
            ),
            if (_debug.practitionerFlow == PractitionerFlow.reuseMeshRef)
              ListTile(
                title: const Text('Prior mesh scan'),
                subtitle: Text(
                  _debug.meshRefSessionId ?? 'Tap to choose from saved scans',
                ),
                trailing: const Icon(Icons.folder_open),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_pickPriorMeshScan());
                },
              ),
            if (_debug.practitionerFlow == PractitionerFlow.meshThenPhotos)
              ListTile(
                title: const Text('Mesh motion'),
                subtitle: _debug.meshMotion == MeshMotionMode.head
                    ? const Text('Patient turns head · device still')
                    : const Text('You orbit iPad · patient still'),
                trailing: _SettingsSegmented<MeshMotionMode>(
                  values: MeshMotionMode.values,
                  selected: _debug.meshMotion,
                  labelOf: (MeshMotionMode m) => m.label,
                  onChanged: (MeshMotionMode m) => _debug.meshMotion = m,
                ),
              ),
            ListTile(
              title: const Text('Photo camera'),
              subtitle: _debug.clinicianCamera == ClinicianCamera.rear
                  ? Text(
                      _debug.practitionerFlow ==
                              PractitionerFlow.meshThenPhotos
                          ? 'Mesh then rear · bake from front'
                          : _debug.practitionerFlow ==
                                  PractitionerFlow.reuseMeshRef
                              ? 'Prior mesh · rear enrichment'
                              : 'Vision guide · no mesh bake',
                    )
                  : _debug.practitionerFlow == PractitionerFlow.reuseMeshRef
                      ? const Text('Prior mesh · new photos as enrichment')
                      : null,
              trailing: _SettingsSegmented<ClinicianCamera>(
                values: ClinicianCamera.values,
                selected: _debug.clinicianCamera,
                labelOf: (ClinicianCamera c) => c.label,
                onChanged: (ClinicianCamera c) => _debug.clinicianCamera = c,
              ),
            ),
            if (_debug.clinicianCamera == ClinicianCamera.rear)
              ListTile(
                title: const Text('Rear capture'),
                subtitle: _debug.rearCaptureKind == RearCaptureKind.video
                    ? const Text('Best sharp frame per angle')
                    : const Text('Full-res photo per angle'),
                trailing: _SettingsSegmented<RearCaptureKind>(
                  values: RearCaptureKind.values,
                  selected: _debug.rearCaptureKind,
                  labelOf: (RearCaptureKind k) => k.label,
                  onChanged: (RearCaptureKind k) => _debug.rearCaptureKind = k,
                ),
              ),
            ListTile(
              title: const Text('Stability'),
              subtitle: _debug.stabilityProfile == CaptureStabilityProfile.tripod
                  ? const Text('Tighter angles · ~1.2 s hold')
                  : const Text('Forgiving · ~2.5 s hold'),
              trailing: _SettingsSegmented<CaptureStabilityProfile>(
                values: CaptureStabilityProfile.values,
                selected: _debug.stabilityProfile,
                labelOf: (CaptureStabilityProfile p) => p.label,
                onChanged: (CaptureStabilityProfile p) =>
                    _debug.stabilityProfile = p,
              ),
            ),
          ],
          const Divider(height: 1),
          SwitchListTile(
            title: const Text('Face mesh overlay'),
            value: _debug.showMesh,
            onChanged: (bool v) => _debug.showMesh = v,
          ),
          if (_debug.isDev) ...<Widget>[
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
            SwitchListTile(
              title: const Text('Calibration HUD'),
              value: _debug.showHud,
              onChanged: (bool v) => _debug.showHud = v,
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
              subtitle: const Text(
                'On = reuse ISO/shutter/WB from the first pose of each '
                'camera pass (front hi-res + rear photo/video). '
                'Off = auto per pose.',
              ),
              value: _debug.lockAeAwb,
              onChanged: (bool v) => _debug.lockAeAwb = v,
            ),
          ],
        ];
      },
    ));
  }

  void _openBakeSettings() {
    unawaited(_openSettingsPage(
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
                    'Off = all poses → default '
                    '${CaptureDefaults.neutralKelvin.round()} K.'
                : 'Enable ml-wb first.',
          ),
          value: _debug.mlWbMatchFrontal,
          onChanged:
              _debug.mlWb ? (bool v) => _debug.mlWbMatchFrontal = v : null,
        ),
        const Divider(height: 1),
        SwitchListTile(
          title: const Text('Fill eye holes'),
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
                        : 'ml-wb → ${CaptureDefaults.neutralKelvin.round()} K')
                    : 'ml-wb off'),
          ),
          enabled: !_baking && _lastSession != null,
          onTap: _baking || _lastSession == null
              ? null
              : () {
                  Navigator.of(context).pop();
                  unawaited(_bakeTexture());
                },
        ),
      ],
    ));
  }

  /// Full-screen settings page (square chrome — no bottom sheet).
  Future<void> _openSettingsPage({
    required String title,
    required List<Widget> Function() buildChildren,
  }) async {
    // Share sheet can leave a native modal that blocks Flutter routes.
    await _trackingService.dismissPresented();
    if (!mounted) {
      return;
    }
    await Navigator.of(context).push<void>(
      PageRouteBuilder<void>(
        pageBuilder: (
          BuildContext pageContext,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
        ) {
          return ListenableBuilder(
            listenable: Listenable.merge(<Listenable>[_debug, _theme]),
            builder: (BuildContext context, Widget? _) {
              final ColorScheme scheme = Theme.of(context).colorScheme;
              const double pageInset = 28;
              return Scaffold(
                backgroundColor: scheme.surface,
                body: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SafeArea(
                      bottom: false,
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(
                          pageInset,
                          12,
                          pageInset - 8,
                          16,
                        ),
                        child: Row(
                          children: <Widget>[
                            Expanded(
                              child: Text(
                                title,
                                style: Theme.of(context)
                                    .textTheme
                                    .titleLarge
                                    ?.copyWith(
                                      fontWeight: FontWeight.w600,
                                      letterSpacing: -0.2,
                                    ),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Close',
                              icon: const Icon(Icons.close),
                              onPressed: () => Navigator.of(context).pop(),
                            ),
                          ],
                        ),
                      ),
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: scheme.onSurface.withValues(alpha: 0.12),
                    ),
                    Expanded(
                      child: Theme(
                        data: Theme.of(context).copyWith(
                          listTileTheme: const ListTileThemeData(
                            contentPadding: EdgeInsets.symmetric(
                              horizontal: 4,
                              vertical: 2,
                            ),
                            minVerticalPadding: 6,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.zero,
                            ),
                          ),
                        ),
                        child: ListView(
                          padding: const EdgeInsets.fromLTRB(
                            pageInset,
                            12,
                            pageInset,
                            48,
                          ),
                          // Rebuild on every notifyListeners — a fixed children
                          // list would freeze SwitchListTile.value at open-time.
                          children: buildChildren(),
                        ),
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
        transitionsBuilder: (
          BuildContext context,
          Animation<double> animation,
          Animation<double> secondaryAnimation,
          Widget child,
        ) {
          return FadeTransition(
            opacity: CurvedAnimation(
              parent: animation,
              curve: Curves.easeOut,
            ),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 180),
        reverseTransitionDuration: const Duration(milliseconds: 140),
      ),
    );
  }

  /// Persists the captured snapshots once the session completes (one-shot).
  Future<void> _persist(CaptureState state) async {
    if (_saving || _didPersistCurrent) {
      return;
    }
    final List<CaptureSnapshot> snapshots =
        _meshSnapshots ?? state.snapshots;
    if (snapshots.isEmpty) {
      return;
    }
    // Bake stills = mesh-pass front; rear enrichment lives in rearStills.
    final Map<FacePose, StillCapture> bakeStills = _meshStills.isNotEmpty
        ? Map<FacePose, StillCapture>.of(_meshStills)
        : Map<FacePose, StillCapture>.of(_stills);
    final Map<FacePose, StillCapture> rearStills = _meshSnapshots != null
        ? Map<FacePose, StillCapture>.of(_stills)
        : const <FacePose, StillCapture>{};
    setState(() => _saving = true);
    try {
      final Directory documents = await getApplicationDocumentsDirectory();
      final FileSnapshotRepository repository = FileSnapshotRepository(
        rootDirectory: documents,
      );
      final CaptureSession session = CaptureSession(
        id: 'session_${DateTime.now().millisecondsSinceEpoch}',
        createdAt: DateTime.now(),
        snapshots: snapshots,
        stills: bakeStills,
        rearStills: rearStills,
        expression: state.expressionMode,
        actorMode: state.actorMode,
        practitionerFlow: state.practitionerFlow,
        meshMotion: state.meshMotion,
        // Persist the clinic photo-camera intent from settings (rear), not the
        // mesh-pass front override used for guidance.
        clinicianCamera: _debug.clinicianCamera,
        rearCaptureKind: state.rearCaptureKind,
        meshRefSessionId: _debug.practitionerFlow == PractitionerFlow.reuseMeshRef
            ? _debug.meshRefSessionId
            : null,
        stabilityProfile: _debug.stabilityProfile,
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
      faceScanLog(
        '$timingLine${mlWbNote != null ? ' | $mlWbNote' : ''}',
      );
      if (mounted) {
        setState(() {
          _baking = false;
          _baked = baked;
        });
      }
    } on Object catch (e) {
      faceScanLog('Bake failed: $e');
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
  ) {
    return applySessionWhiteBalance(
      session: session,
      matchFrontal: _debug.mlWbMatchFrontal,
      targetKelvin: CaptureDefaults.neutralKelvin,
      correct: ({
        required List<Uint8List> jpegs,
        required bool matchFrontal,
        required double targetKelvin,
      }) async {
        final WhiteBalanceResult? result =
            await _trackingService.correctWhiteBalance(
          jpegs: jpegs,
          matchFrontal: matchFrontal,
          targetKelvin: targetKelvin,
        );
        if (result == null) {
          return null;
        }
        return WhiteBalanceCorrection(
          ok: result.ok,
          jpegs: result.jpegs,
          targetKelvin: result.targetKelvin,
          error: result.error,
          timingSummary: result.timingSummary,
        );
      },
    );
  }

  /// Cancels the running scan back to idle and discards the partial captures.
  void _cancelScan() {
    _resetCaptureUiToIdle(playCancelFeedback: true);
    unawaited(_syncIdlePreview());
  }

  void _resetCaptureUiToIdle({required bool playCancelFeedback}) {
    if (playCancelFeedback) {
      CaptureFeedback.cancelled();
    }
    CaptureFeedback.reset();
    _bannerTimer?.cancel();
    if (_bloc.state.status != CaptureStatus.idle) {
      _bloc.add(const CaptureStopped());
    }
    _clearSequentialStash();
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
    final int total = FacePose.captureSequence.length;
    final String banner = switch (_sequentialPass) {
      CapturePass.mesh => 'Mesh · $capturedCount of $total',
      CapturePass.photo => 'Photos · $capturedCount of $total',
      null => PoseGuidanceCopy.capturedProgress(capturedCount, total),
    };
    setState(() => _captureBanner = banner);
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
                if (_sequentialPass == CapturePass.mesh) {
                  // First pass done — hand off to rear without persisting yet.
                  unawaited(_handoffMeshToPhotoPass(state));
                } else {
                  CaptureFeedback.scanCompleted();
                  unawaited(_finishSession(state));
                }
              } else if (state.status == CaptureStatus.error) {
                _clearSequentialStash();
                unawaited(_syncIdlePreview());
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
          backgroundColor: Theme.of(context).scaffoldBackgroundColor,
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              if (_platformPreviewVisible)
                UiKitView(
                  viewType: _trackingService.isRear
                      ? RearFaceTrackingService.previewViewType
                      : CapturePage.previewViewType,
                )
              else
                const ColoredBox(color: Colors.black),
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
              ListenableBuilder(
                listenable: _debug,
                builder: (BuildContext context, Widget? _) =>
                    BlocBuilder<CaptureBloc, CaptureState>(
                  builder: (BuildContext context, CaptureState state) =>
                      CaptureOverlay(
                    state: state,
                    onStart: () => unawaited(_handleStart()),
                    onRetake: () => unawaited(_handleStart()),
                    onGenerateModel: () => unawaited(_bakeTexture()),
                    canGenerateModel: _lastSession != null && !_baking,
                    generatingModel: _baking,
                    onOpenSettings: () =>
                        unawaited(_trackingService.openAppSettings()),
                    targetDistanceMeters: _debug.targetDistanceMeters,
                    captureBanner: _captureBanner,
                    deferPoseGuidance: _awaitingStill,
                    statusLine: _consumerStatusLine(),
                    selectedExpression: _selectedExpression,
                    onExpressionChanged: (ExpressionMode mode) {
                      setState(() => _selectedExpression = mode);
                    },
                    selectedActorMode: _debug.actorMode,
                    selectedPractitionerFlow: _debug.practitionerFlow,
                    selectedMeshMotion: _debug.meshMotion,
                    selectedClinicianCamera: _debug.clinicianCamera,
                    selectedRearCaptureKind: _debug.rearCaptureKind,
                    activeCapturePass: _sequentialPass,
                  ),
                ),
              ),
              // Calibration HUD — Dev-only toggle; ignored for User/Clinician.
              ListenableBuilder(
                listenable: _debug,
                builder: (BuildContext context, Widget? _) =>
                    _debug.isDev && _debug.showHud
                        ? BlocBuilder<CaptureBloc, CaptureState>(
                            builder:
                                (BuildContext context, CaptureState state) =>
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
              // Match CaptureOverlay bottom/side chrome inset (28).
              Positioned(
                top: 0,
                left: 28,
                child: SafeArea(
                  child: BlocBuilder<CaptureBloc, CaptureState>(
                    builder: (BuildContext context, CaptureState state) {
                      if (state.status != CaptureStatus.capturing) {
                        return const SizedBox.shrink();
                      }
                      return Semantics(
                        button: true,
                        label: 'Cancel scan',
                        child: IconButton(
                          tooltip: 'Cancel',
                          style: _chromeIconButtonStyleLeading,
                          icon: const Icon(
                            Icons.close,
                            color: Colors.white70,
                            size: _chromeIconSize,
                          ),
                          onPressed: _cancelScan,
                        ),
                      );
                    },
                  ),
                ),
              ),
              Positioned(
                top: 0,
                right: 28,
                child: SafeArea(
                  child: ListenableBuilder(
                    listenable: _debug,
                    builder: (BuildContext context, Widget? _) => Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: <Widget>[
                        if (_debug.isDev)
                          IconButton(
                            tooltip: 'Bake settings',
                            style: _chromeIconButtonStyle,
                            icon: const Icon(
                              Icons.tune,
                              color: Colors.white70,
                              size: _chromeIconSize,
                            ),
                            onPressed: _openBakeSettings,
                          ),
                        Semantics(
                          button: true,
                          label: 'How to scan',
                          child: IconButton(
                            tooltip: 'How to scan',
                            style: _chromeIconButtonStyle,
                            icon: Icon(
                              Icons.help_outline,
                              color: ScanTheme.accent,
                              size: _chromeIconSize,
                            ),
                            onPressed: _showHowToScan,
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: 'Manage saved scans',
                          child: IconButton(
                            tooltip: 'Saved scans',
                            style: _chromeIconButtonStyle,
                            icon: const Icon(
                              Icons.folder_outlined,
                              color: Colors.white70,
                              size: _chromeIconSize,
                            ),
                            onPressed: _openScansManager,
                          ),
                        ),
                        Semantics(
                          button: true,
                          label: 'Settings',
                          child: IconButton(
                            tooltip: 'Settings',
                            style: _chromeIconButtonStyle,
                            icon: const Icon(
                              Icons.settings,
                              color: Colors.white70,
                              size: _chromeIconSize,
                            ),
                            onPressed: _openSettings,
                          ),
                        ),
                        if (_debug.isDev && _baked != null && !_baking)
                          IconButton(
                            tooltip: 'Share model',
                            style: _chromeIconButtonStyle,
                            icon: const Icon(
                              Icons.ios_share,
                              color: Colors.white70,
                              size: _chromeIconSize,
                            ),
                            onPressed: () => unawaited(_shareModel()),
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

  /// One step above the previous 24px chrome icons.
  static const double _chromeIconSize = 28;

  /// Flush icon glyphs to the 28px chrome inset (same as bottom actions).
  static final ButtonStyle _chromeIconButtonStyle = IconButton.styleFrom(
    padding: EdgeInsets.zero,
    minimumSize: const Size(48, 48),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    alignment: Alignment.centerRight,
  );

  static final ButtonStyle _chromeIconButtonStyleLeading = IconButton.styleFrom(
    padding: EdgeInsets.zero,
    minimumSize: const Size(48, 48),
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    alignment: Alignment.centerLeft,
  );

  String? _consumerStatusLine() {
    if (_saving) {
      return 'Saving…';
    }
    if (_didPersistCurrent && !_baking) {
      final CaptureSession? s = _lastSession;
      if (s != null && s.rearStills.isNotEmpty && s.hasBakeableMesh) {
        return 'Saved · mesh + rear · bake ready';
      }
      return 'Saved on this device';
    }
    if (_sequentialPass == CapturePass.mesh) {
      return 'Pass 1/2 · mesh';
    }
    if (_sequentialPass == CapturePass.photo) {
      return _wantsPriorMeshPhotoOnly
          ? 'Photos · prior mesh'
          : 'Pass 2/2 · rear';
    }
    // Bake / ml-wb timing stays in the bake sheet + console — not on the
    // consumer guidance surface.
    return null;
  }
}

/// Square-bordered dropdown for settings trailing chrome.
class _SettingsDropdown<T extends Object> extends StatelessWidget {
  const _SettingsDropdown({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  static const double _height = 36;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color border = scheme.onSurface.withValues(alpha: 0.22);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: border),
      ),
      child: SizedBox(
        height: _height,
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: selected,
            isDense: true,
            borderRadius: BorderRadius.zero,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  fontSize: 13,
                  color: scheme.onSurface,
                ),
            icon: Icon(
              Icons.expand_more,
              size: 18,
              color: scheme.onSurface.withValues(alpha: 0.55),
            ),
            items: <DropdownMenuItem<T>>[
              for (final T value in values)
                DropdownMenuItem<T>(
                  value: value,
                  child: Text(labelOf(value)),
                ),
            ],
            onChanged: (T? next) {
              if (next != null) {
                onChanged(next);
              }
            },
          ),
        ),
      ),
    );
  }
}

/// Equal-width square segmented control for settings trailing chrome.
class _SettingsSegmented<T extends Object> extends StatelessWidget {
  const _SettingsSegmented({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onChanged,
  });

  final List<T> values;
  final T selected;
  final String Function(T) labelOf;
  final ValueChanged<T> onChanged;

  static const double _height = 36;
  static const double _segmentWidth = 80;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color border = scheme.onSurface.withValues(alpha: 0.22);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: Border.all(color: border),
      ),
      child: SizedBox(
        height: _height,
        width: values.length * _segmentWidth,
        child: Row(
          children: <Widget>[
            for (int i = 0; i < values.length; i++)
              Expanded(
                child: DecoratedBox(
                  decoration: i == 0
                      ? const BoxDecoration()
                      : BoxDecoration(
                          border: Border(
                            left: BorderSide(color: border),
                          ),
                        ),
                  child: _SettingsSegmentCell(
                    label: labelOf(values[i]),
                    selected: values[i] == selected,
                    onTap: () => onChanged(values[i]),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _SettingsSegmentCell extends StatelessWidget {
  const _SettingsSegmentCell({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? ScanTheme.accent : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Center(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? Colors.white : scheme.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
