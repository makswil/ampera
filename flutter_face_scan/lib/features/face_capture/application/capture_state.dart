import 'package:equatable/equatable.dart';

import '../domain/entities/capture_snapshot.dart';
import '../domain/entities/expression_mode.dart';
import '../domain/entities/face_pose.dart';
import '../domain/entities/pose_validation.dart';
import 'capture_status.dart';

/// Immutable snapshot of the guided-capture session.
///
/// A single state class (status + data) rather than many sealed states: every
/// transition shares the same progress data, so this is simpler to render and
/// to assert on in tests, while [status] still encodes the state-machine mode.
final class CaptureState extends Equatable {
  const CaptureState({
    required this.status,
    required this.currentPose,
    required this.completedPoses,
    required this.snapshots,
    required this.lastValidation,
    required this.holdProgress,
    required this.errorMessage,
    this.expressionMode = ExpressionMode.neutral,
  });

  /// Initial, pre-start state.
  const CaptureState.initial()
    : status = CaptureStatus.idle,
      currentPose = null,
      completedPoses = const <FacePose>[],
      snapshots = const <CaptureSnapshot>[],
      lastValidation = null,
      holdProgress = 0,
      errorMessage = null,
      expressionMode = ExpressionMode.neutral;

  final CaptureStatus status;

  /// Pose the user is currently asked to hold; null when idle/completed.
  final FacePose? currentPose;

  /// Poses already captured, in order.
  final List<FacePose> completedPoses;

  /// Accepted snapshots, one per completed pose.
  final List<CaptureSnapshot> snapshots;

  /// Validation of the most recent frame (drives on-screen guidance).
  final PoseValidation? lastValidation;

  /// 0.0–1.0 hold progress toward the next snapshot (time-based).
  final double holdProgress;

  /// Populated only when [status] is [CaptureStatus.error].
  final String? errorMessage;

  /// Expression selected for this run (also persisted on the session).
  final ExpressionMode expressionMode;

  /// Overall session progress (captured poses / total poses).
  double get sessionProgress =>
      completedPoses.length / FacePose.captureSequence.length;

  CaptureState copyWith({
    CaptureStatus? status,
    FacePose? currentPose,
    bool clearCurrentPose = false,
    List<FacePose>? completedPoses,
    List<CaptureSnapshot>? snapshots,
    PoseValidation? lastValidation,
    double? holdProgress,
    String? errorMessage,
    bool clearError = false,
    ExpressionMode? expressionMode,
  }) {
    return CaptureState(
      status: status ?? this.status,
      currentPose: clearCurrentPose ? null : (currentPose ?? this.currentPose),
      completedPoses: completedPoses ?? this.completedPoses,
      snapshots: snapshots ?? this.snapshots,
      lastValidation: lastValidation ?? this.lastValidation,
      holdProgress: holdProgress ?? this.holdProgress,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      expressionMode: expressionMode ?? this.expressionMode,
    );
  }

  @override
  List<Object?> get props => <Object?>[
    status,
    currentPose,
    completedPoses,
    snapshots,
    lastValidation,
    holdProgress,
    errorMessage,
    expressionMode,
  ];
}
