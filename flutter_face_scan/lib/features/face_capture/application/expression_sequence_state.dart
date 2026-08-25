import 'package:equatable/equatable.dart';

import '../domain/entities/expression_sequence_phase.dart';
import '../domain/entities/expression_sequence_result.dart';
import '../domain/entities/face_observation.dart';
import '../domain/entities/face_pose.dart';
import '../domain/entities/pose_validation.dart';

/// Events for [ExpressionSequenceBloc].
sealed class ExpressionSequenceEvent extends Equatable {
  const ExpressionSequenceEvent();

  @override
  List<Object?> get props => <Object?>[];
}

final class ExpressionSequenceStarted extends ExpressionSequenceEvent {
  const ExpressionSequenceStarted({required this.directoryPath});

  /// Documents-root session folder that will receive `expression/`.
  final String directoryPath;

  @override
  List<Object?> get props => <Object?>[directoryPath];
}

final class ExpressionSequenceStopped extends ExpressionSequenceEvent {
  const ExpressionSequenceStopped();
}

final class ExpressionSequenceFrameReceived extends ExpressionSequenceEvent {
  const ExpressionSequenceFrameReceived(this.observation);

  final FaceObservation observation;

  @override
  List<Object?> get props => <Object?>[observation];
}

final class ExpressionSequenceCountdownTick extends ExpressionSequenceEvent {
  const ExpressionSequenceCountdownTick(this.secondsRemaining);

  final int secondsRemaining;

  @override
  List<Object?> get props => <Object?>[secondsRemaining];
}

final class ExpressionSequenceFailed extends ExpressionSequenceEvent {
  const ExpressionSequenceFailed(this.message);

  final String message;

  @override
  List<Object?> get props => <Object?>[message];
}

/// Immutable UI state for expression-sequence capture.
final class ExpressionSequenceState extends Equatable {
  const ExpressionSequenceState({
    required this.phase,
    this.lastValidation,
    this.readyProgress = 0,
    this.supportHoldProgress = 0,
    this.supportPose,
    this.countdownSeconds,
    this.smileScore = 0,
    this.recordingProgress = 0,
    this.result,
    this.errorMessage,
  });

  const ExpressionSequenceState.initial()
    : phase = ExpressionSequencePhase.idle,
      lastValidation = null,
      readyProgress = 0,
      supportHoldProgress = 0,
      supportPose = null,
      countdownSeconds = null,
      smileScore = 0,
      recordingProgress = 0,
      result = null,
      errorMessage = null;

  final ExpressionSequencePhase phase;
  final PoseValidation? lastValidation;

  /// 0–1 progress toward auto-ready while settling.
  final double readyProgress;

  /// 0–1 hold progress while capturing a support still.
  final double supportHoldProgress;

  /// Active support pose during [ExpressionSequencePhase.supportLeft] /
  /// [ExpressionSequencePhase.supportRight] / [ExpressionSequencePhase.supportUp].
  final FacePose? supportPose;

  /// Seconds left on the countdown (3,2,1); null outside countdown.
  final int? countdownSeconds;

  final double smileScore;

  /// 0–1 progress through the record window after effective start.
  final double recordingProgress;

  final ExpressionSequenceResult? result;
  final String? errorMessage;

  bool get isActive =>
      phase != ExpressionSequencePhase.idle &&
      phase != ExpressionSequencePhase.completed &&
      phase != ExpressionSequencePhase.error;

  bool get isSupportPhase =>
      phase == ExpressionSequencePhase.supportLeft ||
      phase == ExpressionSequencePhase.supportRight ||
      phase == ExpressionSequencePhase.supportUp;

  /// Side/chin prep: AE settle or support stills (uses 4-pose LiveGuidance).
  bool get usesMultiposeStyleGuidance =>
      phase == ExpressionSequencePhase.aeSettle || isSupportPhase;

  ExpressionSequenceState copyWith({
    ExpressionSequencePhase? phase,
    PoseValidation? lastValidation,
    double? readyProgress,
    double? supportHoldProgress,
    FacePose? supportPose,
    bool clearSupportPose = false,
    int? countdownSeconds,
    bool clearCountdown = false,
    double? smileScore,
    double? recordingProgress,
    ExpressionSequenceResult? result,
    String? errorMessage,
    bool clearError = false,
  }) {
    return ExpressionSequenceState(
      phase: phase ?? this.phase,
      lastValidation: lastValidation ?? this.lastValidation,
      readyProgress: readyProgress ?? this.readyProgress,
      supportHoldProgress: supportHoldProgress ?? this.supportHoldProgress,
      supportPose: clearSupportPose ? null : (supportPose ?? this.supportPose),
      countdownSeconds: clearCountdown
          ? null
          : (countdownSeconds ?? this.countdownSeconds),
      smileScore: smileScore ?? this.smileScore,
      recordingProgress: recordingProgress ?? this.recordingProgress,
      result: result ?? this.result,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  @override
  List<Object?> get props => <Object?>[
    phase,
    lastValidation,
    readyProgress,
    supportHoldProgress,
    supportPose,
    countdownSeconds,
    smileScore,
    recordingProgress,
    result,
    errorMessage,
  ];
}
