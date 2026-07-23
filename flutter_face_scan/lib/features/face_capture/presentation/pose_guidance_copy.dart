import '../domain/entities/face_pose.dart';
import '../domain/entities/pose_guidance.dart';

/// Single mapping from UI-agnostic domain enums to user-facing copy.
///
/// Isolating strings here keeps the validator/BLoC free of presentation
/// concerns and gives one obvious place to plug in real localization later.
abstract final class PoseGuidanceCopy {
  const PoseGuidanceCopy._();

  static String hint(PoseGuidance guidance) {
    return switch (guidance) {
      PoseGuidance.faceNotDetected => 'Position your face in the frame',
      PoseGuidance.moveCloser => 'Move a little closer',
      PoseGuidance.moveFarther => 'Move a little farther away',
      PoseGuidance.centerFace => 'Center your face and look straight ahead',
      PoseGuidance.turnLeft => 'Turn your head slightly left',
      PoseGuidance.turnRight => 'Turn your head slightly right',
      PoseGuidance.lookUp => 'Lift your chin slightly',
      PoseGuidance.lookDown => 'Lower your chin slightly',
      PoseGuidance.levelHead => 'Keep your head level',
      PoseGuidance.holdSteady => 'Hold steady…',
      PoseGuidance.onTarget => 'Perfect — hold still',
    };
  }

  static String poseInstruction(FacePose pose) {
    return switch (pose) {
      FacePose.frontal => 'Look straight at the camera',
      FacePose.left40 => 'Slowly turn 45° to your left',
      FacePose.right40 => 'Slowly turn 45° to your right',
      FacePose.up => 'Tilt your head back — lift your chin',
    };
  }
}
