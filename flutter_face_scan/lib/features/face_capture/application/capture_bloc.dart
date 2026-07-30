import 'dart:async';

import 'package:bloc/bloc.dart';
import 'package:flutter/services.dart';

import '../domain/entities/capture_snapshot.dart';
import '../domain/entities/face_observation.dart';
import '../domain/entities/face_pose.dart';
import '../domain/entities/pose_validation.dart';
import '../domain/logic/expression_aware_pose_validator.dart';
import '../domain/services/face_tracking_service.dart';
import '../domain/services/pose_validator.dart';
import '../domain/value_objects/pose_tolerance.dart';
import 'capture_event.dart';
import 'capture_state.dart';
import 'capture_status.dart';

/// Drives the V1 guided-capture state machine.
///
/// Pure orchestration: it owns no AR or timing primitives directly — tracking
/// comes through [FaceTrackingService], acceptance through [PoseValidator], and
/// time through the injected [_now] clock. That makes the whole machine
/// deterministic and unit-testable with a fake stream + hand-built frames.
final class CaptureBloc extends Bloc<CaptureEvent, CaptureState> {
  CaptureBloc({
    required FaceTrackingService trackingService,
    required PoseValidator poseValidator,
    PoseTolerance tolerance = const PoseTolerance(),
    DateTime Function() now = DateTime.now,
  }) : _trackingService = trackingService,
       _poseValidator = poseValidator,
       _tolerance = tolerance,
       _now = now,
       super(const CaptureState.initial()) {
    on<CaptureStarted>(_onStarted);
    on<CaptureStopped>(_onStopped);
    on<CaptureFrameReceived>(_onFrameReceived);
    on<CaptureFailed>(_onFailed);
  }

  final FaceTrackingService _trackingService;
  final PoseValidator _poseValidator;
  final PoseTolerance _tolerance;
  final DateTime Function() _now;

  StreamSubscription<FaceObservation>? _subscription;

  /// Accumulated on-target time toward the current pose's [PoseTolerance.holdDuration].
  int _holdElapsedMicros = 0;

  /// Timestamp of the last on-target frame (to accumulate deltas); null while
  /// off-target so a blip's gap isn't counted when the pose resumes.
  DateTime? _lastOnTargetAt;

  /// When the pose first went off-target; null while on-target. Used with
  /// [PoseTolerance.holdGrace] to tolerate brief jitter before resetting.
  DateTime? _offTargetSince;

  void _resetHold() {
    _holdElapsedMicros = 0;
    _lastOnTargetAt = null;
    _offTargetSince = null;
  }

  Future<void> _onStarted(
    CaptureStarted event,
    Emitter<CaptureState> emit,
  ) async {
    _resetHold();
    // Keep expression mode on the decorator in sync when the page wired one.
    final PoseValidator validator = _poseValidator;
    if (validator is ExpressionAwarePoseValidator) {
      validator.mode = event.expressionMode;
    }
    emit(
      CaptureState(
        status: CaptureStatus.capturing,
        currentPose: FacePose.frontal,
        completedPoses: const <FacePose>[],
        snapshots: const <CaptureSnapshot>[],
        lastValidation: null,
        holdProgress: 0,
        errorMessage: null,
        expressionMode: event.expressionMode,
      ),
    );

    try {
      await _trackingService.start();
      await _subscription?.cancel();
      _subscription = _trackingService.observations.listen(
        (FaceObservation observation) => add(CaptureFrameReceived(observation)),
        onError: (Object error) {
          if (error is PlatformException) {
            add(CaptureFailed('${error.code}: ${error.message ?? error.code}'));
          } else {
            add(CaptureFailed(error.toString()));
          }
        },
      );
    } on Object catch (error) {
      if (error is PlatformException) {
        add(CaptureFailed('${error.code}: ${error.message ?? error.code}'));
      } else {
        add(CaptureFailed(error.toString()));
      }
    }
  }

  Future<void> _onStopped(
    CaptureStopped event,
    Emitter<CaptureState> emit,
  ) async {
    // Cancel back to idle. Keep the native session running (don't _teardown) so
    // the camera preview stays live behind the Start button; a later Start just
    // re-subscribes. Full teardown happens on close().
    _resetHold();
    await _stopProcessing();
    emit(const CaptureState.initial());
  }

  void _onFrameReceived(
    CaptureFrameReceived event,
    Emitter<CaptureState> emit,
  ) {
    final FacePose? pose = state.currentPose;
    if (state.status != CaptureStatus.capturing || pose == null) {
      return;
    }

    final PoseValidation validation = _poseValidator.validate(
      pose: pose,
      observation: event.observation,
    );

    final DateTime now = _now();

    if (!validation.isOnTarget) {
      // Off-target: tolerate a brief blip (jitter) without losing progress; only
      // a drift longer than holdGrace resets the accumulated hold.
      _offTargetSince ??= now;
      _lastOnTargetAt = null; // pause: don't count the gap when we resume
      if (now.difference(_offTargetSince!) > _tolerance.holdGrace) {
        _holdElapsedMicros = 0;
      }
      emit(state.copyWith(lastValidation: validation, holdProgress: _progress()));
      return;
    }

    // On target: accumulate the time since the previous on-target frame.
    _offTargetSince = null;
    final DateTime? last = _lastOnTargetAt;
    if (last != null) {
      _holdElapsedMicros += now.difference(last).inMicroseconds;
    }
    _lastOnTargetAt = now;

    if (_progress() < 1.0) {
      emit(state.copyWith(lastValidation: validation, holdProgress: _progress()));
      return;
    }

    _resetHold();
    _commitSnapshot(pose, event.observation, validation, emit);
  }

  double _progress() =>
      (_holdElapsedMicros / _tolerance.holdDuration.inMicroseconds).clamp(
        0.0,
        1.0,
      );

  void _commitSnapshot(
    FacePose pose,
    FaceObservation observation,
    PoseValidation validation,
    Emitter<CaptureState> emit,
  ) {
    final List<FacePose> completed = <FacePose>[...state.completedPoses, pose];
    final List<CaptureSnapshot> snapshots = <CaptureSnapshot>[
      ...state.snapshots,
      CaptureSnapshot(pose: pose, observation: observation, capturedAt: _now()),
    ];

    final FacePose? next = _nextPose(completed);
    if (next == null) {
      emit(
        state.copyWith(
          status: CaptureStatus.completed,
          completedPoses: completed,
          snapshots: snapshots,
          lastValidation: validation,
          holdProgress: 0,
          clearCurrentPose: true,
        ),
      );
      // Stop consuming frames, but DON'T pause the native session — keeping it
      // running leaves the camera preview live on the completion screen instead
      // of freezing on the last frame. Full teardown happens on stop/close.
      unawaited(_stopProcessing());
      return;
    }

    emit(
      state.copyWith(
        currentPose: next,
        completedPoses: completed,
        snapshots: snapshots,
        lastValidation: validation,
        holdProgress: 0,
      ),
    );
  }

  void _onFailed(CaptureFailed event, Emitter<CaptureState> emit) {
    emit(
      state.copyWith(status: CaptureStatus.error, errorMessage: event.message),
    );
    unawaited(_teardown());
  }

  /// First pose in the canonical sequence not yet in [completed].
  FacePose? _nextPose(List<FacePose> completed) {
    for (final FacePose pose in FacePose.captureSequence) {
      if (!completed.contains(pose)) {
        return pose;
      }
    }
    return null;
  }

  /// Stops consuming frames without pausing the native AR session.
  Future<void> _stopProcessing() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  /// Stops processing AND pauses the native session (releases the camera).
  Future<void> _teardown() async {
    await _stopProcessing();
    await _trackingService.stop();
  }

  @override
  Future<void> close() async {
    await _teardown();
    return super.close();
  }
}
