import 'dart:math' as math;

import 'package:equatable/equatable.dart';

/// Head orientation as Tait–Bryan Euler angles, in **degrees**.
///
/// Sign convention (matches ARKit head pose, right-handed, camera-facing user):
///   * [yaw]   — rotation about the vertical axis. + = turning to the user's
///               left from the camera's view; − = to the user's right.
///   * [pitch] — rotation about the lateral axis. + = chin up; − = chin down.
///   * [roll]  — rotation about the view axis. + = tilt to the user's left.
///
/// Immutable value object; equality is by value.
final class EulerAngles extends Equatable {
  const EulerAngles({
    required this.yaw,
    required this.pitch,
    required this.roll,
  });

  /// Neutral orientation (looking straight at the camera).
  const EulerAngles.zero() : yaw = 0, pitch = 0, roll = 0;

  /// Builds Euler angles from radians.
  factory EulerAngles.fromRadians({
    required double yaw,
    required double pitch,
    required double roll,
  }) {
    return EulerAngles(
      yaw: _degrees(yaw),
      pitch: _degrees(pitch),
      roll: _degrees(roll),
    );
  }

  final double yaw;
  final double pitch;
  final double roll;

  static double _degrees(double radians) => radians * 180.0 / math.pi;

  @override
  List<Object?> get props => <Object?>[yaw, pitch, roll];

  @override
  String toString() =>
      'EulerAngles(yaw: ${yaw.toStringAsFixed(1)}, '
      'pitch: ${pitch.toStringAsFixed(1)}, '
      'roll: ${roll.toStringAsFixed(1)})';
}
