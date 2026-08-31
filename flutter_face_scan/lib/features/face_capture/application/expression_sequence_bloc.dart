import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bloc/bloc.dart';
import 'package:flutter/services.dart';

import '../data/arkit_face_tracking_service.dart';
import '../domain/constants/expression_sequence_config.dart';
import '../domain/entities/expression_mode.dart';
import '../domain/entities/expression_sequence_phase.dart';
import '../domain/entities/expression_sequence_result.dart';
import '../domain/entities/face_observation.dart';
import '../domain/entities/face_pose.dart';
import '../domain/entities/pose_validation.dart';
import '../domain/entities/still_capture.dart';
import '../domain/services/face_tracking_service.dart';
import '../domain/services/pose_validator.dart';
import 'expression_sequence_state.dart';

export 'expression_sequence_state.dart';

/// AE settle → L/R/up stills → settle → countdown → buffer → record → hi-res end.
final class ExpressionSequenceBloc
    extends Bloc<ExpressionSequenceEvent, ExpressionSequenceState> {
  ExpressionSequenceBloc({
    required FaceTrackingService trackingService,
    required PoseValidator poseValidator,
    required ArkitFaceTrackingService expressionRecorder,
    DateTime Function() now = DateTime.now,
  }) : _trackingService = trackingService,
       _poseValidator = poseValidator,
       _recorder = expressionRecorder,
       _now = now,
       super(const ExpressionSequenceState.initial()) {
    on<ExpressionSequenceStarted>(_onStarted);
    on<ExpressionSequenceStopped>(_onStopped);
    on<ExpressionSequenceFrameReceived>(_onFrame);
    on<ExpressionSequenceCountdownTick>(_onCountdownTick);
    on<ExpressionSequenceFailed>(_onFailed);
  }

  final FaceTrackingService _trackingService;
  final PoseValidator _poseValidator;
  final ArkitFaceTrackingService _recorder;
  final DateTime Function() _now;

  /// Sample rate passed to native on the next buffer start (Dev settings).
  int targetFps = ExpressionSequenceConfig.targetFps.round();

  /// Same Dev toggle as 4-pose: settle + lock AE/AWB for support stills + clip.
  bool lockAeAwb = true;

  /// One-shot: TrueDepth lock already held from a preceding 4-pose scan — reuse
  /// it instead of settling fresh. Cleared when the run starts.
  bool carryAeLock = false;

  StreamSubscription<FaceObservation>? _subscription;
  Timer? _countdownTimer;
  String? _directoryPath;

  int _readyElapsedMicros = 0;
  DateTime? _lastReadyAt;
  DateTime? _offReadySince;

  int _supportElapsedMicros = 0;
  DateTime? _lastSupportAt;
  DateTime? _offSupportSince;
  bool _supportCapturing = false;
  bool _aeLocked = false;
  bool _finalizing = false;
  FaceObservation? _lastObservation;

  double _baselineSmile = 0;
  bool _onsetLocked = false;
  DateTime? _effectiveStart;
  DateTime? _bufferingSince;
  /// Wall-clock start of the recording *bar* (not the lookback trim window).
  DateTime? _recordBarOrigin;
  int? _effectiveStartMicros;
  bool _countdownStarted = false;

  /// Recent smile samples during recording: (micros, score).
  final List<(int, double)> _smileTrace = <(int, double)>[];

  Future<void> _onStarted(
    ExpressionSequenceStarted event,
    Emitter<ExpressionSequenceState> emit,
  ) async {
    await _resetTimers();
    _directoryPath = event.directoryPath;
    _readyElapsedMicros = 0;
    _lastReadyAt = null;
    _offReadySince = null;
    _supportElapsedMicros = 0;
    _lastSupportAt = null;
    _offSupportSince = null;
    _supportCapturing = false;
    _aeLocked = carryAeLock && lockAeAwb;
    carryAeLock = false;
    _finalizing = false;
    _lastObservation = null;
    _baselineSmile = 0;
    _onsetLocked = false;
    _effectiveStart = null;
    _bufferingSince = null;
    _recordBarOrigin = null;
    _effectiveStartMicros = null;
    _countdownStarted = false;
    _smileTrace.clear();

    emit(
      const ExpressionSequenceState(
        phase: ExpressionSequencePhase.aeSettle,
        supportHoldProgress: 0,
        readyProgress: 0,
      ),
    );

    try {
      await _trackingService.start();
      await _subscription?.cancel();
      _subscription = _trackingService.observations.listen(
        (FaceObservation o) => add(ExpressionSequenceFrameReceived(o)),
        onError: (Object error) {
          if (error is PlatformException) {
            add(
              ExpressionSequenceFailed(
                '${error.code}: ${error.message ?? error.code}',
              ),
            );
          } else {
            add(ExpressionSequenceFailed(error.toString()));
          }
        },
      );
    } on Object catch (error) {
      if (error is PlatformException) {
        add(
          ExpressionSequenceFailed(
            '${error.code}: ${error.message ?? error.code}',
          ),
        );
      } else {
        add(ExpressionSequenceFailed(error.toString()));
      }
    }
  }

  Future<void> _onStopped(
    ExpressionSequenceStopped event,
    Emitter<ExpressionSequenceState> emit,
  ) async {
    await _teardownCapture(cancelNative: true);
    emit(const ExpressionSequenceState.initial());
  }

  Future<void> _onCountdownTick(
    ExpressionSequenceCountdownTick event,
    Emitter<ExpressionSequenceState> emit,
  ) async {
    if (state.phase != ExpressionSequencePhase.countdown) {
      return;
    }
    if (event.secondsRemaining > 0) {
      emit(state.copyWith(countdownSeconds: event.secondsRemaining));
      return;
    }
    final String? dir = _directoryPath;
    if (dir == null) {
      add(const ExpressionSequenceFailed('Expression capture unavailable'));
      return;
    }
    try {
      await _recorder.startExpressionBuffer(
        directoryPath: dir,
        targetFps: targetFps,
      );
    } on Object catch (e) {
      add(ExpressionSequenceFailed(e.toString()));
      return;
    }
    _bufferingSince = _now();
    _baselineSmile = state.smileScore;
    emit(
      state.copyWith(
        phase: ExpressionSequencePhase.buffering,
        clearCountdown: true,
        clearSupportPose: true,
        readyProgress: 1,
        recordingProgress: 0,
      ),
    );
  }

  Future<void> _onFrame(
    ExpressionSequenceFrameReceived event,
    Emitter<ExpressionSequenceState> emit,
  ) async {
    final ExpressionSequencePhase phase = state.phase;
    if (phase == ExpressionSequencePhase.idle ||
        phase == ExpressionSequencePhase.completed ||
        phase == ExpressionSequencePhase.error) {
      return;
    }

    final FaceObservation observation = event.observation;
    _lastObservation = observation;
    final double smile = ExpressionMode.smileScore(observation.blendshapes);
    final DateTime now = _now();

    switch (phase) {
      case ExpressionSequencePhase.aeSettle:
        await _handleAeSettle(
          observation: observation,
          smile: smile,
          now: now,
          emit: emit,
        );
      case ExpressionSequencePhase.supportLeft:
        await _handleSupport(
          pose: FacePose.left40,
          observation: observation,
          smile: smile,
          now: now,
          emit: emit,
          nextPhase: ExpressionSequencePhase.supportRight,
          nextSupportPose: FacePose.right40,
        );
      case ExpressionSequencePhase.supportRight:
        await _handleSupport(
          pose: FacePose.right40,
          observation: observation,
          smile: smile,
          now: now,
          emit: emit,
          nextPhase: ExpressionSequencePhase.supportUp,
          nextSupportPose: FacePose.up,
        );
      case ExpressionSequencePhase.supportUp:
        await _handleSupport(
          pose: FacePose.up,
          observation: observation,
          smile: smile,
          now: now,
          emit: emit,
          nextPhase: ExpressionSequencePhase.settling,
          nextSupportPose: null,
        );
      case ExpressionSequencePhase.settling:
        final PoseValidation validation = _poseValidator.validate(
          pose: FacePose.frontal,
          observation: observation,
        );
        _handleSettling(validation, smile, now, emit);
      case ExpressionSequencePhase.countdown:
        final PoseValidation validation = _poseValidator.validate(
          pose: FacePose.frontal,
          observation: observation,
        );
        emit(state.copyWith(lastValidation: validation, smileScore: smile));
      case ExpressionSequencePhase.buffering:
        final PoseValidation validation = _poseValidator.validate(
          pose: FacePose.frontal,
          observation: observation,
        );
        await _handleBuffering(validation, smile, now, emit);
      case ExpressionSequencePhase.recording:
        final PoseValidation validation = _poseValidator.validate(
          pose: FacePose.frontal,
          observation: observation,
        );
        await _handleRecording(validation, smile, now, emit);
      case ExpressionSequencePhase.hiResEnd:
        // Capture runs once from _finalize; ignore further frames.
        emit(state.copyWith(smileScore: smile));
      case ExpressionSequencePhase.idle:
      case ExpressionSequencePhase.completed:
      case ExpressionSequencePhase.error:
        break;
    }
  }

  Future<void> _handleAeSettle({
    required FaceObservation observation,
    required double smile,
    required DateTime now,
    required Emitter<ExpressionSequenceState> emit,
  }) async {
    if (_supportCapturing) {
      return;
    }

    final PoseValidation validation = _poseValidator.validate(
      pose: FacePose.frontal,
      observation: observation,
    );

    if (!validation.isOnTarget) {
      _offSupportSince ??= now;
      _lastSupportAt = null;
      if (now.difference(_offSupportSince!) >
          const Duration(milliseconds: 350)) {
        _supportElapsedMicros = 0;
      }
      emit(
        state.copyWith(
          lastValidation: validation,
          smileScore: smile,
          clearSupportPose: true,
          supportHoldProgress:
              (_supportElapsedMicros /
                      ExpressionSequenceConfig.aeSettleHold.inMicroseconds)
                  .clamp(0.0, 1.0),
        ),
      );
      return;
    }

    _offSupportSince = null;
    final DateTime? last = _lastSupportAt;
    if (last != null) {
      _supportElapsedMicros += now.difference(last).inMicroseconds;
    }
    _lastSupportAt = now;

    final double progress =
        (_supportElapsedMicros /
                ExpressionSequenceConfig.aeSettleHold.inMicroseconds)
            .clamp(0.0, 1.0);

    if (progress < 1.0) {
      emit(
        state.copyWith(
          lastValidation: validation,
          smileScore: smile,
          clearSupportPose: true,
          supportHoldProgress: progress,
        ),
      );
      return;
    }

    _supportCapturing = true;
    emit(
      state.copyWith(
        lastValidation: validation,
        smileScore: smile,
        clearSupportPose: true,
        supportHoldProgress: 1.0,
      ),
    );
    try {
      // Reuses lockedLook when carried from 4-pose; otherwise settles fresh.
      await _recorder.settleAndLockExpressionAeAwb(lockAeAwb: lockAeAwb);
      _aeLocked = lockAeAwb;
    } on Object catch (e) {
      add(ExpressionSequenceFailed('Camera lock failed: $e'));
      return;
    } finally {
      _supportCapturing = false;
    }

    _supportElapsedMicros = 0;
    _lastSupportAt = null;
    _offSupportSince = null;

    emit(
      ExpressionSequenceState(
        phase: ExpressionSequencePhase.supportLeft,
        lastValidation: validation,
        smileScore: smile,
        supportPose: FacePose.left40,
        supportHoldProgress: 0,
      ),
    );
  }

  Future<void> _handleSupport({
    required FacePose pose,
    required FaceObservation observation,
    required double smile,
    required DateTime now,
    required Emitter<ExpressionSequenceState> emit,
    required ExpressionSequencePhase nextPhase,
    required FacePose? nextSupportPose,
  }) async {
    if (_supportCapturing) {
      return;
    }

    final PoseValidation validation = _poseValidator.validate(
      pose: pose,
      observation: observation,
    );

    if (!validation.isOnTarget) {
      _offSupportSince ??= now;
      _lastSupportAt = null;
      if (now.difference(_offSupportSince!) >
          const Duration(milliseconds: 350)) {
        _supportElapsedMicros = 0;
      }
      emit(
        state.copyWith(
          lastValidation: validation,
          smileScore: smile,
          supportPose: pose,
          supportHoldProgress:
              (_supportElapsedMicros /
                      ExpressionSequenceConfig.supportHold.inMicroseconds)
                  .clamp(0.0, 1.0),
        ),
      );
      return;
    }

    _offSupportSince = null;
    final DateTime? last = _lastSupportAt;
    if (last != null) {
      _supportElapsedMicros += now.difference(last).inMicroseconds;
    }
    _lastSupportAt = now;

    final double progress =
        (_supportElapsedMicros /
                ExpressionSequenceConfig.supportHold.inMicroseconds)
            .clamp(0.0, 1.0);

    if (progress < 1.0) {
      emit(
        state.copyWith(
          lastValidation: validation,
          smileScore: smile,
          supportPose: pose,
          supportHoldProgress: progress,
        ),
      );
      return;
    }

    _supportCapturing = true;
    emit(
      state.copyWith(
        lastValidation: validation,
        smileScore: smile,
        supportPose: pose,
        supportHoldProgress: 1.0,
      ),
    );
    try {
      await _writeSupportStill(pose: pose, observation: observation);
    } on Object catch (e) {
      add(ExpressionSequenceFailed('Support still failed: $e'));
      return;
    } finally {
      _supportCapturing = false;
    }

    _supportElapsedMicros = 0;
    _lastSupportAt = null;
    _offSupportSince = null;

    emit(
      ExpressionSequenceState(
        phase: nextPhase,
        lastValidation: validation,
        smileScore: smile,
        supportPose: nextSupportPose,
        supportHoldProgress: 0,
        readyProgress: 0,
      ),
    );
  }

  /// Writes JPEG + verts + matrices under `expression/support/{pose}/`.
  Future<void> _writeSupportStill({
    required FacePose pose,
    required FaceObservation observation,
  }) async {
    final String? root = _directoryPath;
    if (root == null) {
      throw StateError('no session directory');
    }
    if (observation.rawVertices.isEmpty) {
      throw StateError('no mesh vertices for support still');
    }

    // Same ARKit video frame as the clip — no still-capture hitch.
    final StillCapture? still = await _recorder.captureStill(
      currentFrameOnly: true,
      lockAeAwb: lockAeAwb,
    );
    if (still == null || still.bytes.isEmpty) {
      throw StateError('captureStill returned empty');
    }

    final Directory supportDir = Directory('$root/expression/support');
    await supportDir.create(recursive: true);
    final String stem = pose.name;
    await File('${supportDir.path}/$stem.jpg').writeAsBytes(
      still.bytes,
    );
    final Float32List verts = Float32List.fromList(observation.rawVertices);
    await File('${supportDir.path}/$stem.verts').writeAsBytes(
      verts.buffer.asUint8List(),
    );
    final Map<String, Object?> meta = <String, Object?>{
      'pose': stem,
      'width': still.width,
      'height': still.height,
      'jpg': '$stem.jpg',
      'verts': '$stem.verts',
      'viewMatrix': _matrixList(still.viewMatrix),
      'projectionMatrix': _matrixList(still.projectionMatrix),
      'faceTransform': _matrixList(still.faceTransform),
    };
    await File('${supportDir.path}/$stem.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(meta),
    );
  }

  static List<double> _matrixList(Matrix4 m) =>
      List<double>.generate(16, (int i) => m.storage[i]);

  /// Frontal on-target only — resting faces often score >0.08 smile and used
  /// to block settle forever ("Perfect — hold still" with no countdown).
  void _handleSettling(
    PoseValidation validation,
    double smile,
    DateTime now,
    Emitter<ExpressionSequenceState> emit,
  ) {
    if (!validation.isOnTarget) {
      _offReadySince ??= now;
      _lastReadyAt = null;
      if (now.difference(_offReadySince!) > const Duration(milliseconds: 350)) {
        _readyElapsedMicros = 0;
      }
      emit(
        state.copyWith(
          lastValidation: validation,
          smileScore: smile,
          clearSupportPose: true,
          readyProgress:
              (_readyElapsedMicros /
                      ExpressionSequenceConfig.readyHold.inMicroseconds)
                  .clamp(0.0, 1.0),
        ),
      );
      return;
    }

    _offReadySince = null;
    final DateTime? last = _lastReadyAt;
    if (last != null) {
      _readyElapsedMicros += now.difference(last).inMicroseconds;
    }
    _lastReadyAt = now;

    // Full ring as soon as they are on-target — countdown is the hold.
    final double progress =
        (_readyElapsedMicros /
                ExpressionSequenceConfig.readyHold.inMicroseconds)
            .clamp(0.0, 1.0);

    if (progress < 1.0) {
      emit(
        state.copyWith(
          lastValidation: validation,
          smileScore: smile,
          clearSupportPose: true,
          readyProgress: 1,
        ),
      );
      return;
    }

    if (_countdownStarted) {
      return;
    }
    _countdownStarted = true;
    emit(
      state.copyWith(
        phase: ExpressionSequencePhase.countdown,
        lastValidation: validation,
        smileScore: smile,
        clearSupportPose: true,
        readyProgress: 1,
        countdownSeconds: ExpressionSequenceConfig.countdown.inSeconds,
      ),
    );
    _startCountdown();
  }

  void _startCountdown() {
    _countdownTimer?.cancel();
    int remaining = ExpressionSequenceConfig.countdown.inSeconds;
    add(ExpressionSequenceCountdownTick(remaining));
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (Timer t) {
      remaining -= 1;
      add(ExpressionSequenceCountdownTick(remaining));
      if (remaining <= 0) {
        t.cancel();
      }
    });
  }

  Future<void> _handleBuffering(
    PoseValidation validation,
    double smile,
    DateTime now,
    Emitter<ExpressionSequenceState> emit,
  ) async {
    emit(
      state.copyWith(
        lastValidation: validation,
        smileScore: smile,
        recordingProgress: 0,
      ),
    );

    if (smile < ExpressionSequenceConfig.readyNeutralMaxSmile) {
      _baselineSmile = (_baselineSmile * 0.9) + (smile * 0.1);
    }

    final DateTime? since = _bufferingSince;
    if (since != null &&
        now.difference(since) > ExpressionSequenceConfig.noOnsetTimeout) {
      add(
        const ExpressionSequenceFailed(
          'No motion detected — try again',
        ),
      );
      return;
    }

    final bool onset =
        smile >= ExpressionSequenceConfig.onsetAbsolute ||
        (smile - _baselineSmile) >= ExpressionSequenceConfig.onsetDelta;
    if (!onset || _onsetLocked) {
      return;
    }
    _onsetLocked = true;

    final DateTime effective = now.subtract(
      ExpressionSequenceConfig.onsetLookback,
    );
    _effectiveStart = effective;
    _effectiveStartMicros = effective.microsecondsSinceEpoch;

    try {
      await _recorder.markExpressionStart(
        startMicros: _effectiveStartMicros!,
      );
    } on Object catch (e) {
      add(ExpressionSequenceFailed(e.toString()));
      return;
    }

    _recordBarOrigin = now;
    emit(
      state.copyWith(
        phase: ExpressionSequencePhase.recording,
        lastValidation: validation,
        smileScore: smile,
        recordingProgress: 0,
      ),
    );
    _smileTrace
      ..clear()
      ..add((now.microsecondsSinceEpoch, smile));
  }

  Future<void> _handleRecording(
    PoseValidation validation,
    double smile,
    DateTime now,
    Emitter<ExpressionSequenceState> emit,
  ) async {
    final DateTime? start = _effectiveStart;
    if (start == null) {
      return;
    }

    final int nowMicros = now.microsecondsSinceEpoch;
    _smileTrace.add((nowMicros, smile));
    final int keepAfter = nowMicros -
        ExpressionSequenceConfig.mimicStableFor.inMicroseconds -
        200000;
    _smileTrace.removeWhere(((int, double) e) => e.$1 < keepAfter);

    final Duration elapsed = now.difference(start);
    final DateTime barOrigin = _recordBarOrigin ?? now;
    emit(
      state.copyWith(
        lastValidation: validation,
        smileScore: smile,
        recordingProgress: _recordingBarProgress(now.difference(barOrigin)),
      ),
    );

    if (elapsed < ExpressionSequenceConfig.recordDurationMin) {
      return;
    }
    if (elapsed >= ExpressionSequenceConfig.recordDurationMax) {
      await _finalize(emit);
      return;
    }
    if (_mimicIsStable()) {
      await _finalize(emit);
    }
  }

  bool _mimicIsStable() {
    if (_smileTrace.length < 3) {
      return false;
    }
    double minS = _smileTrace.first.$2;
    double maxS = minS;
    for (final (int, double) sample in _smileTrace) {
      if (sample.$2 < minS) {
        minS = sample.$2;
      }
      if (sample.$2 > maxS) {
        maxS = sample.$2;
      }
    }
    return (maxS - minS) < ExpressionSequenceConfig.mimicChangeEpsilon;
  }

  /// Fast through the 3 s minimum (from 0 → ~85%), then crawl toward 94%
  /// if recording extends. Never completes while we can still keep going.
  static double _recordingBarProgress(Duration elapsed) {
    final int minUs = ExpressionSequenceConfig.recordDurationMin.inMicroseconds;
    final int maxUs = ExpressionSequenceConfig.recordDurationMax.inMicroseconds;
    final int us = elapsed.inMicroseconds;
    if (us <= minUs) {
      final double t = (us / minUs).clamp(0.0, 1.0);
      final double eased = 1 - math.pow(1 - t, 2.4).toDouble();
      return (0.85 * eased).clamp(0.0, 0.85);
    }
    final double extra = ((us - minUs) / (maxUs - minUs)).clamp(0.0, 1.0);
    final double crawl = 1 - math.pow(1 - extra, 2.0).toDouble();
    return (0.85 + 0.09 * crawl).clamp(0.85, 0.94);
  }

  Future<void> _finalize(Emitter<ExpressionSequenceState> emit) async {
    if (_finalizing) {
      return;
    }
    _finalizing = true;

    // Keep the recording UI up while we finish internally.
    emit(
      state.copyWith(
        phase: ExpressionSequencePhase.hiResEnd,
        recordingProgress: state.recordingProgress.clamp(0.0, 0.94),
        clearCountdown: true,
        clearSupportPose: true,
      ),
    );

    // Snapshot smile mesh *before* any still capture — pausing ARKit can
    // reset tracking to a rest pose (last frame looked like the first).
    final FaceObservation? endObs = _lastObservation;
    final double endSmile = state.smileScore;
    StillCapture? endStill;
    try {
      if (endObs != null && endObs.rawVertices.isNotEmpty) {
        // ARKit hi-res frame (same camera as the clip), not AVCapture pause.
        endStill = await _recorder.captureStill(
          hiRes: false,
          lockAeAwb: lockAeAwb,
        );
      }
    } on Object {
      endStill = null;
    }

    try {
      final ExpressionSequenceResult raw = await _recorder
          .finalizeExpressionSequence(
            endMicros: _now().microsecondsSinceEpoch,
          );
      final String manifestPath = raw.manifestPath;
      if (manifestPath.isEmpty || !File(manifestPath).existsSync()) {
        throw StateError(
          'expression finalize: sequence.json missing'
          '${manifestPath.isEmpty ? '' : ' at $manifestPath'}',
        );
      }

      ExpressionSequenceResult result = raw;
      if (endStill != null &&
          endStill.bytes.isNotEmpty &&
          endObs != null &&
          endObs.rawVertices.isNotEmpty) {
        result = await _appendHiResEndFrame(
          result: raw,
          still: endStill,
          observation: endObs,
          smile: endSmile,
        );
      }

      await _writeSessionManifest(result);
      await _teardownCapture(cancelNative: false);
      // Internally done: fill the bar, then drop the scan chrome.
      emit(
        state.copyWith(
          phase: ExpressionSequencePhase.hiResEnd,
          result: result,
          recordingProgress: 1,
          clearCountdown: true,
          clearSupportPose: true,
        ),
      );
      await Future<void>.delayed(const Duration(milliseconds: 700));
      if (isClosed) {
        return;
      }
      emit(
        state.copyWith(
          phase: ExpressionSequencePhase.completed,
          result: result,
          recordingProgress: 1,
          clearCountdown: true,
          clearSupportPose: true,
        ),
      );
    } on Object catch (e) {
      add(ExpressionSequenceFailed(e.toString()));
    }
  }

  /// Appends a frontal hi-res still as the last sequence frame (smile end pose).
  Future<ExpressionSequenceResult> _appendHiResEndFrame({
    required ExpressionSequenceResult result,
    required StillCapture still,
    required FaceObservation observation,
    required double smile,
  }) async {
    final File manifestFile = File(result.manifestPath);
    final Object? decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map<String, dynamic>) {
      return result;
    }
    final List<dynamic> rawFrames =
        decoded['frames'] as List<dynamic>? ?? <dynamic>[];
    int maxIndex = -1;
    for (final dynamic f in rawFrames) {
      if (f is Map && f['index'] is num) {
        final int i = (f['index'] as num).toInt();
        if (i > maxIndex) {
          maxIndex = i;
        }
      }
    }
    final int index = maxIndex + 1;
    final String stem = 'frame_${index.toString().padLeft(4, '0')}';
    final String jpgName = 'frames/$stem.jpg';
    final String vertsName = 'frames/$stem.verts';
    final Directory exprDir = manifestFile.parent;
    final Directory framesDir = Directory('${exprDir.path}/frames');
    await framesDir.create(recursive: true);

    await File('${exprDir.path}/$jpgName').writeAsBytes(
      still.bytes,
      flush: true,
    );
    final Float32List verts = Float32List.fromList(observation.rawVertices);
    await File('${exprDir.path}/$vertsName').writeAsBytes(
      verts.buffer.asUint8List(),
      flush: true,
    );

    rawFrames.add(<String, Object?>{
      'index': index,
      'timestampMicros': _now().microsecondsSinceEpoch,
      'smileScore': smile,
      'jpg': jpgName,
      'verts': vertsName,
      'width': still.width,
      'height': still.height,
      'viewMatrix': _matrixList(still.viewMatrix),
      'projectionMatrix': _matrixList(still.projectionMatrix),
      'faceTransform': _matrixList(still.faceTransform),
      'hiRes': true,
    });
    decoded['frames'] = rawFrames;
    decoded['frameCount'] = rawFrames.length;
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(decoded),
      flush: true,
    );

    return ExpressionSequenceResult(
      directoryPath: result.directoryPath,
      frameCount: rawFrames.length,
      manifestPath: result.manifestPath,
    );
  }

  /// So Scans Manager lists this as an Expression session (label + open).
  Future<void> _writeSessionManifest(ExpressionSequenceResult result) async {
    final String dir = result.directoryPath;
    if (dir.isEmpty) {
      return;
    }
    final String id =
        dir.split('/').where((String s) => s.isNotEmpty).last;
    final Map<String, Object?> manifest = <String, Object?>{
      'id': id,
      'expression': ExpressionMode.smile.name,
      'createdAt': _now().toIso8601String(),
      'frameCount': result.frameCount,
      'expressionManifest': 'expression/sequence.json',
    };
    await File('$dir/manifest.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
      flush: true,
    );
  }

  Future<void> _onFailed(
    ExpressionSequenceFailed event,
    Emitter<ExpressionSequenceState> emit,
  ) async {
    await _teardownCapture(cancelNative: true);
    if (isClosed) {
      return;
    }
    emit(
      state.copyWith(
        phase: ExpressionSequencePhase.error,
        errorMessage: event.message,
        clearCountdown: true,
        clearSupportPose: true,
      ),
    );
  }

  Future<void> _resetTimers() async {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> _teardownCapture({required bool cancelNative}) async {
    await _resetTimers();
    if (_aeLocked) {
      _aeLocked = false;
      try {
        await _recorder.unlockExpressionAeAwb();
      } on Object {
        // Best-effort.
      }
    }
    if (!cancelNative) {
      return;
    }
    try {
      await _recorder.cancelExpressionBuffer();
    } on Object {
      // Best-effort cancel.
    }
    // After a successful finalize the clip (+ support stills) must stay on
    // disk. Native cancel is then a no-op (expressionDir already cleared).
    if (state.phase == ExpressionSequencePhase.completed) {
      return;
    }
    // Support stills live under expression/ before the native buffer starts;
    // cancelExpressionBuffer is a no-op then — wipe the folder ourselves.
    // Never delete a finalized clip (sequence.json) — teardown can race finalize.
    final String? root = _directoryPath;
    if (root != null) {
      final Directory expr = Directory('$root/expression');
      final File sequence = File('${expr.path}/sequence.json');
      if (expr.existsSync() && !sequence.existsSync()) {
        try {
          await expr.delete(recursive: true);
        } on Object {
          // Best-effort.
        }
      }
    }
  }

  @override
  Future<void> close() async {
    await _teardownCapture(cancelNative: true);
    return super.close();
  }
}
