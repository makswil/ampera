import 'package:equatable/equatable.dart';

import 'face_observation.dart';
import 'face_pose.dart';

/// A frame that was accepted and frozen for a target [pose] during capture.
///
/// Holds the full [observation] (vertices + blendshapes + orientation) so the
/// V3 reconstruction stage has everything it needs without re-querying ARKit.
final class CaptureSnapshot extends Equatable {
  const CaptureSnapshot({
    required this.pose,
    required this.observation,
    required this.capturedAt,
  });

  /// The guided pose this snapshot satisfies.
  final FacePose pose;

  /// The accepted face-tracking frame.
  final FaceObservation observation;

  /// Wall-clock capture time (for ordering / auditing).
  final DateTime capturedAt;

  @override
  List<Object?> get props => <Object?>[pose, observation, capturedAt];
}
