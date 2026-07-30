/// The discrete head poses the V1 guided-capture flow asks the user to hold.
///
/// Ordering of [FacePose.values] defines the capture sequence.
enum FacePose {
  /// Looking straight at the camera.
  frontal(targetYaw: 0, targetPitch: 0, label: 'Front'),

  /// Head turned ~40° to the user's left (camera sees the right cheek).
  left40(targetYaw: 35, targetPitch: 0, label: 'Left'),

  /// Head turned ~40° to the user's right (camera sees the left cheek).
  right40(targetYaw: -35, targetPitch: 0, label: 'Right'),

  /// Chin raised (head tilted back) so the camera sees under the nose and chin —
  /// areas that only graze the frontal/side views and otherwise bake distorted.
  /// Positive pitch = looking up (see [EulerAngles] sign convention).
  up(targetYaw: 0, targetPitch: 22, label: 'Chin up');

  const FacePose({
    required this.targetYaw,
    required this.targetPitch,
    required this.label,
  });

  /// Ideal yaw (degrees) for this pose. See [EulerAngles] sign convention.
  final double targetYaw;

  /// Ideal pitch (degrees) for this pose; positive = chin up / looking up.
  /// Zero for all poses except [up].
  final double targetPitch;

  /// Human-readable label for on-screen guidance.
  final String label;

  /// The canonical capture order for V1.
  static List<FacePose> get captureSequence => FacePose.values;
}
