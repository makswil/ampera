/// Discrete, UI-agnostic correction hints emitted by the pose validator.
///
/// The presentation layer maps these to copy / arrows / haptics. Keeping them
/// as an enum (not localized strings) keeps validation logic pure and testable.
enum PoseGuidance {
  faceNotDetected,
  moveCloser,
  moveFarther,
  centerFace,
  turnLeft,
  turnRight,
  lookUp,
  lookDown,
  levelHead,
  /// Expression gate: smile coefficients below threshold.
  smileMore,
  holdSteady,
  onTarget,
}
