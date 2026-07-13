import 'dart:async';
import 'dart:io';

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
import '../domain/constants/face_vertex_indices.dart';
import '../domain/entities/capture_session.dart';
import '../domain/entities/face_pose.dart';
import '../domain/entities/saved_session.dart';
import '../domain/entities/still_capture.dart';
import '../domain/logic/guided_pose_validator.dart';
import '../domain/logic/least_squares_symmetry_axis_extractor.dart';
import '../domain/services/symmetry_axis_extractor.dart';
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
  final DebugSettings _debug = DebugSettings();

  SavedSession? _saved;
  bool _saving = false;

  /// Kept after a successful save so the texture can be re-baked (e.g. when the
  /// eyes toggle changes) without re-capturing.
  CaptureSession? _lastSession;
  Directory? _lastDir;
  bool _baking = false;

  /// Paths of the last baked model (obj/mtl/png), for the share sheet.
  BakedTexture? _baked;

  /// One RGB still + projection per pose, grabbed as each pose completes.
  final Map<FacePose, StillCapture> _stills = <FacePose, StillCapture>{};
  int _lastCompletedCount = 0;

  /// Serializes the per-pose still grabs so the session can await them all
  /// (including the final pose's) before persisting.
  Future<void> _stillChain = Future<void>.value();

  Future<void> _grabStill(FacePose pose) async {
    final StillCapture? still = await _trackingService.captureStill();
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
    // Don't auto-start: the user starts each scan from the Start button so the
    // preview + guidance don't run until asked.
    _bloc = CaptureBloc(
      trackingService: _trackingService,
      poseValidator: const GuidedPoseValidator(axisExtractor: extractor),
    );

    // Re-push the overlay config whenever a debug toggle changes.
    _debug.addListener(_applyOverlay);
    _applyOverlay();
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
    _debug.removeListener(_applyOverlay);
    _debug.dispose();
    // Bloc.close() tears down the tracking subscription/session.
    unawaited(_bloc.close());
    unawaited(_trackingService.dispose());
    super.dispose();
  }

  void _openDebugSheet() {
    unawaited(
      showModalBottomSheet<void>(
        context: context,
        builder: (BuildContext sheetContext) => ListenableBuilder(
          listenable: _debug,
          builder: (BuildContext context, Widget? _) => SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
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
                  title: const Text('Fill eye/mouth holes'),
                  subtitle: const Text('Off = leave ARKit holes in the model'),
                  value: _debug.fillHoles,
                  onChanged: (bool v) => _debug.fillHoles = v,
                ),
                ListTile(
                  title: const Text('Texture resolution'),
                  subtitle: const Text('Bake output size (px)'),
                  trailing: DropdownButton<int>(
                    value: _debug.textureSize,
                    items: <DropdownMenuItem<int>>[
                      for (final int size in DebugSettings.textureSizeOptions)
                        DropdownMenuItem<int>(
                          value: size,
                          child: Text(size == 0 ? 'Original' : '$size'),
                        ),
                    ],
                    onChanged: (int? v) {
                      if (v != null) {
                        _debug.textureSize = v;
                      }
                    },
                  ),
                ),
                if (_saved != null)
                  ListTile(
                    leading: _baking
                        ? const SizedBox(
                            width: 24,
                            height: 24,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.brush_outlined),
                    title: const Text('Re-bake texture'),
                    subtitle: Text(_baking
                        ? 'Baking…'
                        : 'Apply the current eyes setting'),
                    onTap: _baking
                        ? null
                        : () {
                            Navigator.pop(sheetContext);
                            unawaited(_bakeTexture());
                          },
                  ),
                ListTile(
                  leading: const Icon(Icons.folder_outlined),
                  title: const Text('Manage saved scans'),
                  onTap: () {
                    Navigator.pop(sheetContext);
                    unawaited(
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => const ScansManagerPage(),
                        ),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Persists the captured snapshots once the session completes (one-shot).
  Future<void> _persist(CaptureState state) async {
    if (_saving || _saved != null || state.snapshots.isEmpty) {
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
          _saved = saved;
          _saving = false;
        });
      }
      await _bakeTexture(); // uses the current eyes toggle
    } on Object {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// Bakes (or re-bakes) the last saved session's texture with the current eyes
  /// setting and writes model.obj/.mtl/.png into its folder. No-op if nothing is
  /// saved yet or a bake is already running.
  Future<void> _bakeTexture() async {
    final CaptureSession? session = _lastSession;
    final Directory? dir = _lastDir;
    if (session == null || dir == null || _baking) {
      return;
    }
    setState(() => _baking = true);
    try {
      final BakedTexture? baked = await const SessionTextureBaker().bake(
        session: session,
        directory: dir,
        fillHoles: _debug.fillHoles,
        textureSize: _debug.textureSize,
      );
      if (mounted) {
        setState(() {
          _baking = false;
          _baked = baked;
        });
      }
    } on Object {
      if (mounted) {
        setState(() => _baking = false);
      }
    }
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
    await _trackingService.shareFiles(<String>[
      baked.objPath,
      baked.mtlPath,
      baked.texturePath,
    ]);
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
              (_saved != null || _saving || _stills.isNotEmpty)) {
            // A brand-new session (retake) — completedPoses reset to empty.
            // Clear previous result + stills. (Must NOT fire mid-session, or it
            // would wipe already-captured stills.)
            setState(() {
              _saved = null;
              _saving = false;
              _lastSession = null;
              _lastDir = null;
              _baked = null;
              _stills.clear();
              _stillChain = Future<void>.value();
              _lastCompletedCount = 0;
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
                  statusLine: _saving
                      ? 'Saving…'
                      : _baking
                          ? 'Baking texture…'
                          : null,
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
              // Action icons grouped on one side (top-right): cancel (while
              // capturing), share (once baked), tools/settings.
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
                        if (kShowDevMenu)
                          IconButton(
                            tooltip: 'Tools',
                            icon: const Icon(
                              Icons.settings,
                              color: Colors.white70,
                              size: 24,
                            ),
                            onPressed: _openDebugSheet,
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
}
