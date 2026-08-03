import '../domain/entities/capture_actor_mode.dart';
import '../domain/entities/expression_mode.dart';
import '../domain/entities/face_pose.dart';
import '../domain/entities/pose_guidance.dart';

/// User-facing copy for pose guidance (swap later for localization).
abstract final class PoseGuidanceCopy {
  const PoseGuidanceCopy._();

  static String hint(
    PoseGuidance guidance, {
    double expressionScore = double.nan,
    CaptureActorMode actorMode = CaptureActorMode.user,
  }) {
    if (actorMode == CaptureActorMode.practitioner) {
      return switch (guidance) {
        PoseGuidance.faceNotDetected => 'Find the face in the outline',
        PoseGuidance.moveCloser => 'Move closer',
        PoseGuidance.moveFarther => 'Move farther',
        PoseGuidance.centerFace => 'Center the face',
        // left40 yaw → camera sees the patient's right cheek (and vice versa).
        PoseGuidance.turnLeft => 'Right side of the face',
        PoseGuidance.turnRight => 'Left side of the face',
        // Chin-up target: lower the iPad to look up under the chin.
        PoseGuidance.lookUp => 'Under the chin',
        PoseGuidance.lookDown => 'Move up',
        PoseGuidance.levelHead => 'Level the iPad',
        PoseGuidance.smileMore => expressionScore.isNaN
            ? 'Ask to smile more'
            : 'Ask to smile more (${expressionScore.toStringAsFixed(2)})',
        PoseGuidance.holdSteady => 'Hold steady…',
        PoseGuidance.onTarget => 'Perfect — hold still',
      };
    }
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
      PoseGuidance.smileMore => expressionScore.isNaN
          ? 'Smile a bit more'
          : 'Smile a bit more (${expressionScore.toStringAsFixed(2)})',
      PoseGuidance.holdSteady => 'Hold steady…',
      PoseGuidance.onTarget => 'Perfect — hold still',
    };
  }

  /// What we want for this pose (title), without angle jargon.
  static String poseInstruction(
    FacePose pose, {
    ExpressionMode expression = ExpressionMode.neutral,
    CaptureActorMode actorMode = CaptureActorMode.user,
  }) {
    if (actorMode == CaptureActorMode.practitioner) {
      final String base = switch (pose) {
        FacePose.frontal => 'Front of the face',
        FacePose.left40 => 'Right side of the face',
        FacePose.right40 => 'Left side of the face',
        FacePose.up => 'Under the chin',
      };
      if (expression == ExpressionMode.smile) {
        return '$base · keep smile';
      }
      return base;
    }
    if (expression == ExpressionMode.smile) {
      return switch (pose) {
        FacePose.frontal => 'Look straight and smile',
        FacePose.left40 => 'Turn left — keep smiling',
        FacePose.right40 => 'Turn right — keep smiling',
        FacePose.up => 'Lift your chin — keep smiling',
      };
    }
    return switch (pose) {
      FacePose.frontal => 'Look straight at the camera',
      FacePose.left40 => 'Slowly turn left',
      FacePose.right40 => 'Slowly turn right',
      FacePose.up => 'Tilt your head back — lift your chin',
    };
  }

  static String capturedProgress(int captured, int total) =>
      'Captured $captured of $total';

  static String idleHeadline(
    ExpressionMode expression, {
    CaptureActorMode actorMode = CaptureActorMode.user,
    PractitionerFlow practitionerFlow = PractitionerFlow.meshThenPhotos,
    MeshMotionMode meshMotion = MeshMotionMode.device,
    ClinicianCamera clinicianCamera = ClinicianCamera.front,
    RearCaptureKind rearCaptureKind = RearCaptureKind.still,
  }) {
    if (actorMode != CaptureActorMode.practitioner) {
      return switch (expression) {
        ExpressionMode.neutral => '4 angles of your face',
        ExpressionMode.smile => '4 angles while you smile',
      };
    }

    final bool rear = clinicianCamera == ClinicianCamera.rear;
    final bool rearVideo = rear && rearCaptureKind == RearCaptureKind.video;
    final bool priorMesh =
        practitionerFlow == PractitionerFlow.reuseMeshRef;
    final bool headMesh =
        practitionerFlow == PractitionerFlow.meshThenPhotos &&
        meshMotion == MeshMotionMode.head;

    if (priorMesh) {
      if (!rear) {
        return 'Prior mesh · new photos';
      }
      return rearVideo ? 'Prior mesh · rear video' : 'Prior mesh · rear photos';
    }
    if (rear) {
      if (headMesh) {
        return rearVideo ? 'Head mesh · then rear video' : 'Head mesh · then rear photos';
      }
      return rearVideo
          ? 'Rear video · sharpest frames'
          : 'Rear photo · patient still';
    }
    if (headMesh) {
      return 'Patient turns head · mesh';
    }
    return 'Move the iPad · patient still';
  }

  static String idleReady(CaptureActorMode actorMode) =>
      actorMode == CaptureActorMode.practitioner
          ? 'Clinician scan'
          : 'Ready to scan';

  static String get completedHeadline => 'All angles captured';

  static String get completedSubtitle => 'Your scan is saved on this device';
}
