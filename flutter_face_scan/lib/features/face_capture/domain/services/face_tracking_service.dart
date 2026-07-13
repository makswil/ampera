import '../entities/face_observation.dart';

/// Port to a TrueDepth face-tracking source.
///
/// The domain depends only on this abstraction; the ARKit implementation lives
/// in the data layer. This is the seam that keeps the BLoC testable with a fake
/// stream and decoupled from `ARKitSceneView`.
abstract interface class FaceTrackingService {
  /// Continuous stream of mapped frames. Emits [FaceObservation.lost] frames
  /// while no face is tracked.
  Stream<FaceObservation> get observations;

  /// Begins the AR session / face tracking. Idempotent.
  Future<void> start();

  /// Stops tracking and releases session resources. Idempotent.
  Future<void> stop();
}
