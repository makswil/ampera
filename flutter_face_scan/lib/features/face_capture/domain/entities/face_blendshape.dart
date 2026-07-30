/// Subset of ARKit `ARFaceAnchor.blendShapes` coefficients (0.0–1.0) relevant
/// to dynamic (expression) capture.
///
/// Kept as a typed enum rather than raw `String` keys so V2 logic and tests
/// stay refactor-safe. [arkitKey] maps to the native `ARBlendShapeLocation`.
enum FaceBlendshape {
  jawOpen('jawOpen'),
  mouthSmileLeft('mouthSmileLeft'),
  mouthSmileRight('mouthSmileRight'),
  mouthStretchLeft('mouthStretchLeft'),
  mouthStretchRight('mouthStretchRight'),
  mouthPucker('mouthPucker'),
  browInnerUp('browInnerUp'),
  browDownLeft('browDownLeft'),
  browDownRight('browDownRight'),
  eyeBlinkLeft('eyeBlinkLeft'),
  eyeBlinkRight('eyeBlinkRight'),
  cheekPuff('cheekPuff'),
  cheekSquintLeft('cheekSquintLeft'),
  cheekSquintRight('cheekSquintRight'),
  noseSneerLeft('noseSneerLeft'),
  noseSneerRight('noseSneerRight');

  const FaceBlendshape(this.arkitKey);

  /// Native ARKit blendshape location key.
  final String arkitKey;

  /// Reverse lookup from a native key; null if not tracked here.
  static FaceBlendshape? fromArkitKey(String key) {
    for (final FaceBlendshape shape in FaceBlendshape.values) {
      if (shape.arkitKey == key) {
        return shape;
      }
    }
    return null;
  }
}
