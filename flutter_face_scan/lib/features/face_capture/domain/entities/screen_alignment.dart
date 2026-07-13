import 'package:equatable/equatable.dart';

/// Result of fitting the symmetry axis in **2D normalized screen space**.
///
/// Used to decide whether the user is facing the camera (frontal) before the
/// first snapshot, independent of any first-frame reference.
final class ScreenAlignment extends Equatable {
  const ScreenAlignment({
    required this.tiltDegrees,
    required this.straightness,
    required this.centerOffsetX,
    required this.centerOffsetY,
  });

  /// Tilt of the fitted 2D midline from screen-vertical, in degrees (0 = upright).
  final double tiltDegrees;

  /// Mean perpendicular distance of the points from the fitted line, in
  /// normalized screen units (0 = perfectly straight). On a frontal, upright
  /// head this is small; yaw bends the projected midline and raises it.
  final double straightness;

  /// Horizontal offset of the midline centroid from screen centre (x − 0.5).
  final double centerOffsetX;

  /// Vertical offset of the midline centroid from screen centre (y − 0.5).
  final double centerOffsetY;

  @override
  List<Object?> get props => <Object?>[
    tiltDegrees,
    straightness,
    centerOffsetX,
    centerOffsetY,
  ];
}
