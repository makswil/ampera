import '../domain/entities/face_pose.dart';
import '../domain/entities/pose_guidance.dart';

/// User-facing copy for pose guidance (swap later for localization).
abstract final class PoseGuidanceCopy {
  const PoseGuidanceCopy._();

  static String hint(PoseGuidance guidance) {
    return switch (guidance) {
      PoseGuidance.faceNotDetected => 'Position your face in the outline',
      PoseGuidance.moveCloser => 'Move a little closer',
      PoseGuidance.moveFarther => 'Move a little farther away',
      PoseGuidance.centerFace => 'Center your face in the outline',
      PoseGuidance.turnLeft => 'Turn left',
      PoseGuidance.turnRight => 'Turn right',
      PoseGuidance.lookUp => 'Lift your chin',
      PoseGuidance.lookDown => 'Lower your chin',
      PoseGuidance.levelHead => 'Keep your head level',
      PoseGuidance.holdSteady => 'Hold steady…',
      PoseGuidance.onTarget => 'Perfect — hold still',
    };
  }

  /// What we want for this pose (title), without angle jargon.
  static String poseInstruction(FacePose pose) {
    return switch (pose) {
      FacePose.frontal => 'Look straight at the camera',
      FacePose.left40 => 'Slowly turn left',
      FacePose.right40 => 'Slowly turn right',
      FacePose.up => 'Tilt your head back — lift your chin',
    };
  }

  static String capturedProgress(int captured, int total) =>
      'Captured $captured of $total';

  static String get idleHeadline => "We'll capture 4 angles of your face";

  static String get idleReady => 'Ready to scan';

  static String get completedHeadline => 'All angles captured';

  static String get completedSubtitle => 'Your scan is saved on this device';
}
