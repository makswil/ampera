import '../entities/face_observation.dart';
import '../entities/face_pose.dart';
import '../entities/pose_validation.dart';

/// Validates whether a frame satisfies a target guided pose.
///
/// The single, stable interface for pose acceptance (maintainability anchor):
/// V2 dynamic capture and any future ML-based validator implement the same
/// contract, so the BLoC never changes.
abstract interface class PoseValidator {
  /// Pure, side-effect-free validation of [observation] against [pose].
  PoseValidation validate({
    required FacePose pose,
    required FaceObservation observation,
  });
}
