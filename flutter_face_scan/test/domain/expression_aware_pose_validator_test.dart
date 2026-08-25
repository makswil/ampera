import 'package:flutter_face_scan/features/face_capture/domain/entities/euler_angles.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/expression_mode.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/face_blendshape.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/face_observation.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/face_pose.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/pose_guidance.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/pose_validation.dart';
import 'package:flutter_face_scan/features/face_capture/domain/logic/expression_aware_pose_validator.dart';
import 'package:flutter_face_scan/features/face_capture/domain/services/pose_validator.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/face_observation_fixtures.dart';

class _AlwaysOnTarget implements PoseValidator {
  @override
  PoseValidation validate({
    required FacePose pose,
    required FaceObservation observation,
  }) {
    return const PoseValidation(
      isOnTarget: true,
      guidance: <PoseGuidance>[PoseGuidance.onTarget],
      yawError: 0,
      pitchError: 0,
      rollError: 0,
      axisTilt: 0,
      axisResidual: 0,
    );
  }
}

class _AlwaysOffTarget implements PoseValidator {
  @override
  PoseValidation validate({
    required FacePose pose,
    required FaceObservation observation,
  }) {
    return const PoseValidation(
      isOnTarget: false,
      guidance: <PoseGuidance>[PoseGuidance.turnLeft],
      yawError: 10,
      pitchError: 0,
      rollError: 0,
      axisTilt: 0,
      axisResidual: 0,
    );
  }
}

void main() {
  FaceObservation frame({Map<FaceBlendshape, double> blendshapes =
      const <FaceBlendshape, double>{}}) {
    return observationOnLine(
      eulerAngles: const EulerAngles.zero(),
      blendshapes: blendshapes,
    );
  }

  test('neutral mode is a pass-through of the inner validator', () {
    final ExpressionAwarePoseValidator validator = ExpressionAwarePoseValidator(
      inner: _AlwaysOnTarget(),
    );

    final PoseValidation result = validator.validate(
      pose: FacePose.frontal,
      observation: frame(),
    );

    expect(result.isOnTarget, isTrue);
    expect(result.guidance, <PoseGuidance>[PoseGuidance.onTarget]);
  });

  test('smile mode no longer hold-gates — pass-through (sequence owns smile)', () {
    final ExpressionAwarePoseValidator validator = ExpressionAwarePoseValidator(
      inner: _AlwaysOnTarget(),
      mode: ExpressionMode.smile,
    );

    final PoseValidation result = validator.validate(
      pose: FacePose.frontal,
      observation: frame(
        blendshapes: const <FaceBlendshape, double>{
          FaceBlendshape.mouthSmileLeft: 0.05,
          FaceBlendshape.mouthSmileRight: 0.05,
        },
      ),
    );

    expect(ExpressionMode.smile.requiresExpressionGate, isFalse);
    expect(result.isOnTarget, isTrue);
    expect(result.guidance, <PoseGuidance>[PoseGuidance.onTarget]);
  });

  test('smileScore uses mouthSmile / cheekSquint / stretch', () {
    expect(
      ExpressionMode.smileScore(const <FaceBlendshape, double>{
        FaceBlendshape.mouthSmileLeft: ExpressionMode.smileMinScore,
        FaceBlendshape.mouthSmileRight: ExpressionMode.smileMinScore,
      }),
      greaterThanOrEqualTo(ExpressionMode.smileMinScore),
    );
    expect(
      ExpressionMode.smileScore(const <FaceBlendshape, double>{
        FaceBlendshape.cheekSquintLeft: 0.4,
        FaceBlendshape.cheekSquintRight: 0.35,
      }),
      greaterThan(0.3),
    );
    expect(
      ExpressionMode.smileScore(const <FaceBlendshape, double>{
        FaceBlendshape.mouthSmileLeft: 0.5,
      }),
      greaterThan(0.4),
    );
  });

  test('pose guidance from inner still wins', () {
    final ExpressionAwarePoseValidator validator = ExpressionAwarePoseValidator(
      inner: _AlwaysOffTarget(),
      mode: ExpressionMode.smile,
    );

    final PoseValidation result = validator.validate(
      pose: FacePose.frontal,
      observation: frame(),
    );

    expect(result.isOnTarget, isFalse);
    expect(result.guidance, <PoseGuidance>[PoseGuidance.turnLeft]);
  });
}
