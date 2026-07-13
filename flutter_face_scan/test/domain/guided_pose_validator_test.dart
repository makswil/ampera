import 'package:flutter_face_scan/features/face_capture/domain/entities/euler_angles.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/face_observation.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/face_pose.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/pose_guidance.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/pose_validation.dart';
import 'package:flutter_face_scan/features/face_capture/domain/logic/guided_pose_validator.dart';
import 'package:flutter_face_scan/features/face_capture/domain/logic/least_squares_symmetry_axis_extractor.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/face_observation_fixtures.dart';

void main() {
  const GuidedPoseValidator validator = GuidedPoseValidator(
    axisExtractor: LeastSquaresSymmetryAxisExtractor(),
  );

  PoseValidation validate(FacePose pose, EulerAngles angles) {
    return validator.validate(
      pose: pose,
      observation: observationOnLine(eulerAngles: angles),
    );
  }

  test('frontal + neutral + upright axis is on target', () {
    final PoseValidation result = validate(
      FacePose.frontal,
      const EulerAngles.zero(),
    );

    expect(result.isOnTarget, isTrue);
    expect(result.guidance, <PoseGuidance>[PoseGuidance.onTarget]);
  });

  test('left40 reaches target at +40° yaw', () {
    final PoseValidation result = validate(
      FacePose.left40,
      const EulerAngles(yaw: 40, pitch: 0, roll: 0),
    );

    expect(result.isOnTarget, isTrue);
  });

  test('too far left of frontal asks to turn right', () {
    final PoseValidation result = validate(
      FacePose.frontal,
      const EulerAngles(yaw: 20, pitch: 0, roll: 0),
    );

    expect(result.isOnTarget, isFalse);
    expect(result.guidance, contains(PoseGuidance.turnRight));
  });

  test('chin up asks to look down', () {
    final PoseValidation result = validate(
      FacePose.frontal,
      const EulerAngles(yaw: 0, pitch: 20, roll: 0),
    );

    expect(result.guidance, contains(PoseGuidance.lookDown));
  });

  test('head tilt asks to level head', () {
    final PoseValidation result = validate(
      FacePose.frontal,
      const EulerAngles(yaw: 0, pitch: 0, roll: 20),
    );

    expect(result.guidance, contains(PoseGuidance.levelHead));
  });

  test('untracked frame reports face lost', () {
    final PoseValidation result = validator.validate(
      pose: FacePose.frontal,
      observation: const FaceObservation.lost(Duration.zero),
    );

    expect(result.guidance, <PoseGuidance>[PoseGuidance.faceNotDetected]);
  });

  group('face-frame distance gate', () {
    test('too far away asks to move closer', () {
      final PoseValidation result = validator.validate(
        pose: FacePose.frontal,
        observation: observationOnLine(
          eulerAngles: const EulerAngles.zero(),
          distanceMeters: 0.5, // target 0.32 ± 0.06
        ),
      );

      expect(result.guidance, contains(PoseGuidance.moveCloser));
    });

    test('too close asks to move farther', () {
      final PoseValidation result = validator.validate(
        pose: FacePose.frontal,
        observation: observationOnLine(
          eulerAngles: const EulerAngles.zero(),
          distanceMeters: 0.2,
        ),
      );

      expect(result.guidance, contains(PoseGuidance.moveFarther));
    });

    test('within tolerance does not nudge distance', () {
      final PoseValidation result = validator.validate(
        pose: FacePose.frontal,
        observation: observationOnLine(
          eulerAngles: const EulerAngles.zero(),
          distanceMeters: 0.32,
        ),
      );

      expect(result.isOnTarget, isTrue);
    });
  });

  group('2D screen-axis gate (frontal only)', () {
    test('frontal with a straight, centred 2D axis is on target', () {
      final PoseValidation result = validator.validate(
        pose: FacePose.frontal,
        observation: observationOnLine(
          eulerAngles: const EulerAngles.zero(),
          axisScreenPoints: straightScreenAxis(),
        ),
      );

      expect(result.isOnTarget, isTrue);
    });

    test('a tilted 2D axis asks to level the head', () {
      final PoseValidation result = validator.validate(
        pose: FacePose.frontal,
        observation: observationOnLine(
          eulerAngles: const EulerAngles.zero(),
          axisScreenPoints: straightScreenAxis(tilt: 0.3),
        ),
      );

      expect(result.guidance, contains(PoseGuidance.levelHead));
    });

    test('frontal with an off-centre 2D axis asks to center the face', () {
      final PoseValidation result = validator.validate(
        pose: FacePose.frontal,
        observation: observationOnLine(
          eulerAngles: const EulerAngles.zero(),
          axisScreenPoints: straightScreenAxis(centerX: 0.8),
        ),
      );

      expect(result.isOnTarget, isFalse);
      expect(result.guidance, contains(PoseGuidance.centerFace));
    });

    test('frontal with a bent (turned-head) 2D axis is rejected', () {
      final PoseValidation result = validator.validate(
        pose: FacePose.frontal,
        observation: observationOnLine(
          eulerAngles: const EulerAngles.zero(),
          axisScreenPoints: straightScreenAxis(bend: 0.45),
        ),
      );

      expect(result.guidance, contains(PoseGuidance.centerFace));
    });

    test('the 2D gate does NOT apply to a 40° pose', () {
      final PoseValidation result = validator.validate(
        pose: FacePose.left40,
        observation: observationOnLine(
          eulerAngles: const EulerAngles(yaw: 40, pitch: 0, roll: 0),
          axisScreenPoints: straightScreenAxis(bend: 0.45), // bent is fine here
        ),
      );

      expect(result.isOnTarget, isTrue);
    });

    test('a tilted 2D axis does NOT block a 40° pose (roll is frontal-only)', () {
      final PoseValidation result = validator.validate(
        pose: FacePose.left40,
        observation: observationOnLine(
          eulerAngles: const EulerAngles(yaw: 40, pitch: 0, roll: 0),
          axisScreenPoints: straightScreenAxis(tilt: 0.4), // strongly tilted
        ),
      );

      expect(result.isOnTarget, isTrue);
      expect(result.guidance, isNot(contains(PoseGuidance.levelHead)));
    });
  });
}
