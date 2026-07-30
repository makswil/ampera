import 'package:equatable/equatable.dart';

import 'pose_guidance.dart';

/// Outcome of validating a single [FaceObservation] against a target pose.
///
/// Pure data: no side effects, fully comparable — ideal for golden unit tests.
final class PoseValidation extends Equatable {
  const PoseValidation({
    required this.isOnTarget,
    required this.guidance,
    required this.yawError,
    required this.pitchError,
    required this.rollError,
    required this.axisTilt,
    required this.axisResidual,
    this.screenAxisTilt = double.nan,
    this.screenStraightness = double.nan,
    this.screenCenterOffset = double.nan,
    this.distanceMeters = double.nan,
    this.expressionScore = double.nan,
  });

  /// A "face lost" result with no measurements.
  const PoseValidation.faceLost()
    : isOnTarget = false,
      guidance = const <PoseGuidance>[PoseGuidance.faceNotDetected],
      yawError = double.nan,
      pitchError = double.nan,
      rollError = double.nan,
      axisTilt = double.nan,
      axisResidual = double.nan,
      screenAxisTilt = double.nan,
      screenStraightness = double.nan,
      screenCenterOffset = double.nan,
      distanceMeters = double.nan,
      expressionScore = double.nan;

  /// True when every constraint (orientation + symmetry axis) is satisfied.
  final bool isOnTarget;

  /// Ordered correction hints; contains only [PoseGuidance.onTarget] when valid.
  final List<PoseGuidance> guidance;

  /// Signed yaw deviation from target (degrees).
  final double yawError;

  /// Signed pitch deviation from neutral (degrees).
  final double pitchError;

  /// Signed roll deviation from neutral (degrees).
  final double rollError;

  /// Symmetry-axis tilt from vertical (degrees).
  final double axisTilt;

  /// Symmetry-axis line-fit residual (metres).
  final double axisResidual;

  /// 2D screen-projected midline tilt from vertical (degrees); NaN if N/A.
  final double screenAxisTilt;

  /// 2D screen-projected midline straightness residual (normalized); NaN if N/A.
  final double screenStraightness;

  /// 2D midline distance from screen centre (normalized); NaN if N/A.
  final double screenCenterOffset;

  /// Camera-to-face distance in metres; NaN if N/A.
  final double distanceMeters;

  /// Live expression score (0–1) when an expression gate ran; NaN otherwise.
  final double expressionScore;

  @override
  List<Object?> get props => <Object?>[
    isOnTarget,
    guidance,
    yawError,
    pitchError,
    rollError,
    axisTilt,
    axisResidual,
    screenAxisTilt,
    screenStraightness,
    screenCenterOffset,
    distanceMeters,
    expressionScore,
  ];
}
