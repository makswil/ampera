import 'package:equatable/equatable.dart';

/// Acceptance thresholds for validating a held pose. Centralised so capture
/// strictness is tunable in one place and identical across logic and tests.
final class PoseTolerance extends Equatable {
  const PoseTolerance({
    this.yawToleranceDegrees = 5,
    this.pitchToleranceDegrees = 5,
    this.rollToleranceDegrees = 5,
    this.maxScreenStraightness = 0.02,
    this.maxScreenCenterOffset = 0.12,
    this.targetDistanceMeters = 0.32,
    this.distanceToleranceMeters = 0.06,
    this.holdDuration = const Duration(milliseconds: 2500),
    this.holdGrace = const Duration(milliseconds: 350),
  });

  /// Allowed |yaw − target| for the pose to count as on-target.
  final double yawToleranceDegrees;

  /// Allowed |pitch| (chin up/down) — applies to every pose.
  final double pitchToleranceDegrees;

  /// Allowed |roll| (head tilt) — applies to every pose. The roll signal is the
  /// 2D screen-axis tilt (reliable in portrait), not the 3D camera roll.
  final double rollToleranceDegrees;

  /// Max 2D midline straightness residual in normalized screen units. Above
  /// this the projected midline is bent → not facing the camera (frontal gate).
  final double maxScreenStraightness;

  /// Max distance of the 2D midline centroid from screen centre (frontal gate).
  final double maxScreenCenterOffset;

  /// Target camera-to-face distance (metres) — keeps the face at a constant size
  /// across all captures (the "face frame").
  final double targetDistanceMeters;

  /// Allowed deviation from [targetDistanceMeters] before the user is nudged to
  /// move closer / farther. Ignored when distance is unavailable (tests).
  final double distanceToleranceMeters;

  /// How long the pose must be held on-target before a snapshot is taken
  /// (fps-independent). Accumulated on-target time, not a continuous streak.
  final Duration holdDuration;

  /// Grace window: the pose may drift off-target for up to this long without
  /// losing accumulated hold progress (absorbs momentary tracking jitter). Only
  /// a drift longer than this resets the hold.
  final Duration holdGrace;

  @override
  List<Object?> get props => <Object?>[
    yawToleranceDegrees,
    pitchToleranceDegrees,
    rollToleranceDegrees,
    maxScreenStraightness,
    maxScreenCenterOffset,
    targetDistanceMeters,
    distanceToleranceMeters,
    holdDuration,
    holdGrace,
  ];
}
