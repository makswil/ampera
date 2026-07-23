import 'dart:math' as math;

import '../entities/euler_angles.dart';
import '../entities/face_observation.dart';
import '../entities/face_pose.dart';
import '../entities/pose_guidance.dart';
import '../entities/pose_validation.dart';
import '../entities/screen_alignment.dart';
import '../entities/symmetry_axis.dart';
import '../services/pose_validator.dart';
import '../services/symmetry_axis_extractor.dart';
import '../value_objects/pose_tolerance.dart';
import 'screen_axis_aligner.dart';

/// Default V1 validator: a frame is on-target when its (camera-relative) yaw
/// matches the pose's target, pitch/roll are near-neutral, AND the fitted
/// symmetry axis is upright with a clean fit.
///
/// For the **frontal** pose it additionally requires the 2D screen-projected
/// midline to be straight and centred — a first-frame-independent "facing the
/// camera" gate, so capture only begins when the user is actually centred.
///
/// Pure and deterministic — depends only on injected collaborators, so it is
/// trivially unit-tested with hand-built observations.
final class GuidedPoseValidator implements PoseValidator {
  const GuidedPoseValidator({
    required SymmetryAxisExtractor axisExtractor,
    PoseTolerance tolerance = const PoseTolerance(),
    ScreenAxisAligner screenAligner = const ScreenAxisAligner(),
  }) : _axisExtractor = axisExtractor,
       _tolerance = tolerance,
       _screenAligner = screenAligner;

  final SymmetryAxisExtractor _axisExtractor;
  final PoseTolerance _tolerance;
  final ScreenAxisAligner _screenAligner;

  @override
  PoseValidation validate({
    required FacePose pose,
    required FaceObservation observation,
  }) {
    if (!observation.isTracked) {
      return const PoseValidation.faceLost();
    }

    final EulerAngles angles = observation.eulerAngles;
    final double yawError = angles.yaw - pose.targetYaw;
    final double pitchError = angles.pitch - pose.targetPitch;

    final SymmetryAxis? axis = _axisExtractor.extract(observation);
    final double axisTilt = axis?.tiltDegrees ?? double.nan;
    final double axisResidual = axis?.residual ?? double.nan;

    // Head tilt ("level") from the 2D screen-projected symmetry axis — computed
    // in the correct portrait orientation, so it is the reliable roll signal
    // (the 3D camera-relative roll is rotated ~90° on a portrait hold). Falls
    // back to the Euler roll when no projected points exist (e.g. unit tests).
    final ScreenAlignment? screen = _screenAligner.evaluate(
      observation.axisScreenPoints,
    );
    final double screenAxisTilt = screen?.tiltDegrees ?? double.nan;
    final double screenStraightness = screen?.straightness ?? double.nan;
    final double screenCenterOffset = screen == null
        ? double.nan
        : math.sqrt(
            screen.centerOffsetX * screen.centerOffsetX +
                screen.centerOffsetY * screen.centerOffsetY,
          );
    final double rollError = screen?.tiltDegrees ?? angles.roll;

    final List<PoseGuidance> guidance = <PoseGuidance>[];

    // Face-frame: keep a constant camera distance (constant face size). Only
    // when a distance is available (device); 0 means unknown (unit tests).
    final double distance = observation.distanceMeters;
    if (distance > 0) {
      final double distanceError = distance - _tolerance.targetDistanceMeters;
      if (distanceError > _tolerance.distanceToleranceMeters) {
        guidance.add(PoseGuidance.moveCloser); // too far away
      } else if (distanceError < -_tolerance.distanceToleranceMeters) {
        guidance.add(PoseGuidance.moveFarther); // too close
      }
    }

    if (yawError.abs() > _tolerance.yawToleranceDegrees) {
      // yaw is + to the user's left; positive error => turned too far left.
      guidance.add(
        yawError > 0 ? PoseGuidance.turnRight : PoseGuidance.turnLeft,
      );
    }
    if (pitchError.abs() > _tolerance.pitchToleranceDegrees) {
      guidance.add(pitchError > 0 ? PoseGuidance.lookDown : PoseGuidance.lookUp);
    }
    // Roll ("level head") is only meaningful for the frontal pose: the 2D
    // midline is vertical only when facing the camera. On a turned (40°) head
    // the projected midline legitimately leans from perspective + face
    // curvature, so checking it there would block a perfectly level pose.
    if (pose == FacePose.frontal &&
        rollError.abs() > _tolerance.rollToleranceDegrees) {
      guidance.add(PoseGuidance.levelHead);
    }

    // NOTE: no 3D symmetry-axis residual gate. The 3D midline is never straight
    // (it follows the nose/face curvature), so its residual is meaningless as a
    // pose check. Straightness is validated in 2D below (frontal) and via the
    // level/yaw/pitch checks. axisTilt/axisResidual are kept for diagnostics.

    // Frontal-only "facing camera" gate: the projected midline must be straight
    // (not bent by a turned head) and centred. Tilt is handled by levelHead
    // above, so this checks straightness + centering only. Skipped when the
    // backend supplies no projected points (e.g. unit tests).
    if (screen != null && pose == FacePose.frontal) {
      final bool straight = screenStraightness <= _tolerance.maxScreenStraightness;
      final bool centered = screenCenterOffset <= _tolerance.maxScreenCenterOffset;
      if (!straight || !centered) {
        guidance.add(PoseGuidance.centerFace);
      }
    }

    final bool isOnTarget = guidance.isEmpty;
    return PoseValidation(
      isOnTarget: isOnTarget,
      guidance: isOnTarget
          ? const <PoseGuidance>[PoseGuidance.onTarget]
          : guidance,
      yawError: yawError,
      pitchError: pitchError,
      rollError: rollError,
      axisTilt: axisTilt,
      axisResidual: axisResidual,
      screenAxisTilt: screenAxisTilt,
      screenStraightness: screenStraightness,
      screenCenterOffset: screenCenterOffset,
      distanceMeters: distance,
    );
  }
}
