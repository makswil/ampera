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

  test('smile mode rejects on-target pose when smile score is low', () {
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

    expect(result.isOnTarget, isFalse);
    expect(result.guidance, <PoseGuidance>[PoseGuidance.smileMore]);
  });

  test('smile mode accepts mouthSmile averages above the score floor', () {
    final ExpressionAwarePoseValidator validator = ExpressionAwarePoseValidator(
      inner: _AlwaysOnTarget(),
      mode: ExpressionMode.smile,
    );

    final PoseValidation result = validator.validate(
      pose: FacePose.frontal,
      observation: frame(
        blendshapes: const <FaceBlendshape, double>{
          FaceBlendshape.mouthSmileLeft: ExpressionMode.smileMinScore,
          FaceBlendshape.mouthSmileRight: ExpressionMode.smileMinScore,
        },
      ),
    );

    expect(result.isOnTarget, isTrue);
    expect(result.guidance, <PoseGuidance>[PoseGuidance.onTarget]);
  });

  test('smile mode accepts cheekSquint when mouthSmile is absent', () {
    final ExpressionAwarePoseValidator validator = ExpressionAwarePoseValidator(
      inner: _AlwaysOnTarget(),
      mode: ExpressionMode.smile,
    );

    final PoseValidation result = validator.validate(
      pose: FacePose.frontal,
      observation: frame(
        blendshapes: const <FaceBlendshape, double>{
          FaceBlendshape.cheekSquintLeft: 0.4,
          FaceBlendshape.cheekSquintRight: 0.35,
        },
      ),
    );

    expect(result.isOnTarget, isTrue);
  });

  test('smile mode accepts a strong one-sided mouthSmile', () {
    final ExpressionAwarePoseValidator validator = ExpressionAwarePoseValidator(
      inner: _AlwaysOnTarget(),
      mode: ExpressionMode.smile,
    );

    final PoseValidation result = validator.validate(
      pose: FacePose.frontal,
      observation: frame(
        blendshapes: const <FaceBlendshape, double>{
          FaceBlendshape.mouthSmileLeft: 0.5,
        },
      ),
    );

    expect(result.isOnTarget, isTrue);
  });

  test('pose guidance wins over missing smile', () {
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
