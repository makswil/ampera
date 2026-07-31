import 'package:equatable/equatable.dart';

import '../domain/entities/capture_actor_mode.dart';
import '../domain/entities/expression_mode.dart';
import '../domain/entities/face_observation.dart';

/// Events driving the [CaptureBloc] state machine.
sealed class CaptureEvent extends Equatable {
  const CaptureEvent();

  @override
  List<Object?> get props => <Object?>[];
}

/// User starts (or restarts) the guided capture; subscribes to the tracker.
final class CaptureStarted extends CaptureEvent {
  const CaptureStarted({
    this.expressionMode = ExpressionMode.neutral,
    this.actorMode = CaptureActorMode.user,
    this.practitionerFlow = PractitionerFlow.meshThenPhotos,
    this.meshMotion = MeshMotionMode.device,
    this.clinicianCamera = ClinicianCamera.front,
    this.rearCaptureKind = RearCaptureKind.still,
  });

  /// Facial expression to gate during this run.
  final ExpressionMode expressionMode;

  /// Who operates the device (patient vs clinician).
  final CaptureActorMode actorMode;

  /// Clinician sub-flow; ignored when [actorMode] is [CaptureActorMode.user].
  final PractitionerFlow practitionerFlow;

  /// Mesh-pass motion; ignored unless clinician + mesh now.
  final MeshMotionMode meshMotion;

  /// Clinician photo camera; ignored for user scans.
  final ClinicianCamera clinicianCamera;

  /// Rear photo vs video; ignored unless clinician + rear.
  final RearCaptureKind rearCaptureKind;

  @override
  List<Object?> get props => <Object?>[
    expressionMode,
    actorMode,
    practitionerFlow,
    meshMotion,
    clinicianCamera,
    rearCaptureKind,
  ];
}

/// User aborts / leaves; tears down the AR session.
final class CaptureStopped extends CaptureEvent {
  const CaptureStopped();
}

/// A new tracking frame arrived. Internal — emitted by the bloc's own stream
/// subscription, not by the UI.
final class CaptureFrameReceived extends CaptureEvent {
  const CaptureFrameReceived(this.observation);

  final FaceObservation observation;

  @override
  List<Object?> get props => <Object?>[observation];
}

/// The tracking stream errored.
final class CaptureFailed extends CaptureEvent {
  const CaptureFailed(this.message);

  final String message;

  @override
  List<Object?> get props => <Object?>[message];
}
