/// The discrete head poses the V1 guided-capture flow asks the user to hold.
///
/// Ordering of [FacePose.values] defines the capture sequence.
enum FacePose {
  /// Looking straight at the camera.
  frontal(targetYaw: 0, label: 'Frontal'),

  /// Head turned ~40° to the user's left (camera sees the right cheek).
  left40(targetYaw: 35, label: 'Left 40°'),

  /// Head turned ~40° to the user's right (camera sees the left cheek).
  right40(targetYaw: -35, label: 'Right 40°');

  const FacePose({required this.targetYaw, required this.label});

  /// Ideal yaw (degrees) for this pose. See [EulerAngles] sign convention.
  final double targetYaw;

  /// Human-readable label for on-screen guidance.
  final String label;

  /// The canonical capture order for V1.
  static List<FacePose> get captureSequence => FacePose.values;
}
