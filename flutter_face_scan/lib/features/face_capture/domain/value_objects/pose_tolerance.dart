import 'package:equatable/equatable.dart';

/// Handheld vs tripod capture strictness (parameters only — no hardware detect).
enum CaptureStabilityProfile {
  /// Default clinic / self-scan: forgiving jitter, ~2.5 s hold.
  handheld(label: 'Hand'),

  /// Device on a stand: tighter angles, shorter hold, less grace.
  tripod(label: 'Tripod');

  const CaptureStabilityProfile({required this.label});

  final String label;

  static CaptureStabilityProfile fromName(String? name) {
    if (name == null || name.isEmpty) {
      return CaptureStabilityProfile.handheld;
    }
    for (final CaptureStabilityProfile p in CaptureStabilityProfile.values) {
      if (p.name == name) {
        return p;
      }
    }
    return CaptureStabilityProfile.handheld;
  }
}

/// Acceptance thresholds for validating a held pose. Centralised so capture
/// strictness is tunable in one place and identical across logic and tests.
final class PoseTolerance extends Equatable {
  const PoseTolerance({
    this.yawToleranceDegrees = 5,
    this.pitchToleranceDegrees = 5,
    this.rollToleranceDegrees = 5,
    this.maxScreenStraightness = 0.02,
    this.maxScreenCenterOffset = 0.12,
    this.targetDistanceMeters = kDefaultTargetDistanceMeters,
    this.distanceToleranceMeters = 0.06,
    this.holdDuration = const Duration(milliseconds: 2500),
    this.holdGrace = const Duration(milliseconds: 350),
  });

  /// Preset for [profile], keeping the face-frame [targetDistanceMeters].
  factory PoseTolerance.forProfile(
    CaptureStabilityProfile profile, {
    double targetDistanceMeters = kDefaultTargetDistanceMeters,
  }) {
    final double distance = targetDistanceMeters.clamp(
      kMinTargetDistanceMeters,
      kMaxTargetDistanceMeters,
    );
    return switch (profile) {
      CaptureStabilityProfile.handheld => PoseTolerance(
        targetDistanceMeters: distance,
      ),
      CaptureStabilityProfile.tripod => PoseTolerance(
        yawToleranceDegrees: 3,
        pitchToleranceDegrees: 3,
        rollToleranceDegrees: 3,
        maxScreenStraightness: 0.015,
        maxScreenCenterOffset: 0.08,
        targetDistanceMeters: distance,
        distanceToleranceMeters: 0.04,
        holdDuration: const Duration(milliseconds: 1200),
        holdGrace: const Duration(milliseconds: 150),
      ),
    };
  }

  /// Default face-frame distance: close enough for denser face pixels, still
  /// OK for side/chin-up poses without clipping (TrueDepth FOV).
  static const double kDefaultTargetDistanceMeters = 0.25;

  /// Slider / tune range (metres). Below ~0.20 → tracking + side-pose clip risk.
  static const double kMinTargetDistanceMeters = 0.20;
  static const double kMaxTargetDistanceMeters = 0.40;

  /// Historical reference distance the on-screen oval was drawn for; used to
  /// scale the guide oval when [targetDistanceMeters] changes.
  static const double kReferenceFaceFrameDistanceMeters = 0.32;

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
