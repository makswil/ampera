import '../entities/expression_mode.dart';
import '../entities/face_observation.dart';
import '../entities/face_pose.dart';
import '../entities/pose_guidance.dart';
import '../entities/pose_validation.dart';
import '../services/pose_validator.dart';

/// Decorates any [PoseValidator] with an optional expression (blendshape) gate.
///
/// Reuses the existing head-pose checks unchanged: when [mode] is [ExpressionMode.neutral]
/// this is a pure pass-through. For other modes, pose guidance wins first; only
/// once the head pose is on-target does the expression threshold apply.
final class ExpressionAwarePoseValidator implements PoseValidator {
  ExpressionAwarePoseValidator({
    required PoseValidator inner,
    ExpressionMode mode = ExpressionMode.neutral,
  }) : _inner = inner,
       mode = mode;

  final PoseValidator _inner;

  /// Mutable so the capture page can switch mode without rebuilding the bloc.
  ExpressionMode mode;

  @override
  PoseValidation validate({
    required FacePose pose,
    required FaceObservation observation,
  }) {
    final PoseValidation poseResult = _inner.validate(
      pose: pose,
      observation: observation,
    );
    if (!mode.requiresExpressionGate || !poseResult.isOnTarget) {
      return poseResult;
    }
    final double score = ExpressionMode.smileScore(observation.blendshapes);
    if (mode == ExpressionMode.smile
        ? score >= ExpressionMode.smileMinScore
        : mode.satisfies(observation.blendshapes)) {
      return PoseValidation(
        isOnTarget: true,
        guidance: const <PoseGuidance>[PoseGuidance.onTarget],
        yawError: poseResult.yawError,
        pitchError: poseResult.pitchError,
        rollError: poseResult.rollError,
        axisTilt: poseResult.axisTilt,
        axisResidual: poseResult.axisResidual,
        screenAxisTilt: poseResult.screenAxisTilt,
        screenStraightness: poseResult.screenStraightness,
        screenCenterOffset: poseResult.screenCenterOffset,
        distanceMeters: poseResult.distanceMeters,
        expressionScore: score,
      );
    }
    return PoseValidation(
      isOnTarget: false,
      guidance: mode.missingGuidance,
      yawError: poseResult.yawError,
      pitchError: poseResult.pitchError,
      rollError: poseResult.rollError,
      axisTilt: poseResult.axisTilt,
      axisResidual: poseResult.axisResidual,
      screenAxisTilt: poseResult.screenAxisTilt,
      screenStraightness: poseResult.screenStraightness,
      screenCenterOffset: poseResult.screenCenterOffset,
      distanceMeters: poseResult.distanceMeters,
      expressionScore: score,
    );
  }
}
