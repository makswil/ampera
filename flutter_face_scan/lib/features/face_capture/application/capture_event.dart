import 'package:equatable/equatable.dart';

import '../domain/entities/face_observation.dart';

/// Events driving the [CaptureBloc] state machine.
sealed class CaptureEvent extends Equatable {
  const CaptureEvent();

  @override
  List<Object?> get props => <Object?>[];
}

/// User starts (or restarts) the guided capture; subscribes to the tracker.
final class CaptureStarted extends CaptureEvent {
  const CaptureStarted();
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
