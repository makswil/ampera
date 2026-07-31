import 'package:flutter_face_scan/features/face_capture/domain/entities/capture_actor_mode.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/expression_mode.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/face_pose.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/pose_guidance.dart';
import 'package:flutter_face_scan/features/face_capture/presentation/pose_guidance_copy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('PoseGuidanceCopy clinician', () {
    test('hints name the face side being scanned', () {
      expect(
        PoseGuidanceCopy.hint(
          PoseGuidance.turnLeft,
          actorMode: CaptureActorMode.practitioner,
        ),
        'Right side of the face',
      );
      expect(
        PoseGuidanceCopy.hint(
          PoseGuidance.lookUp,
          actorMode: CaptureActorMode.practitioner,
        ),
        'Under the chin',
      );
    });

    test('pose instructions name the face side being scanned', () {
      expect(
        PoseGuidanceCopy.poseInstruction(
          FacePose.left40,
          actorMode: CaptureActorMode.practitioner,
        ),
        'Right side of the face',
      );
      expect(
        PoseGuidanceCopy.poseInstruction(
          FacePose.up,
          expression: ExpressionMode.smile,
          actorMode: CaptureActorMode.practitioner,
        ),
        'Under the chin · keep smile',
      );
    });

    test('user mode keeps head-turn copy', () {
      expect(
        PoseGuidanceCopy.hint(PoseGuidance.turnLeft),
        'Turn left',
      );
      expect(
        PoseGuidanceCopy.poseInstruction(FacePose.left40),
        'Slowly turn left',
      );
    });
  });
}
