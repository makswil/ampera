import 'dart:math' as math;

import 'face_blendshape.dart';
import 'pose_guidance.dart';

/// Facial expression the guided scan asks the user to hold.
///
/// Reuses the same head-pose sequence as neutral; non-neutral modes add a
/// blendshape gate on top of [GuidedPoseValidator].
enum ExpressionMode {
  /// Relaxed face — no blendshape gate (default / legacy sessions).
  neutral(label: 'Neutral'),

  /// Smile held for the whole pose sequence.
  smile(label: 'Smile');

  const ExpressionMode({required this.label});

  /// Short UI label for pickers and scan lists.
  final String label;

  /// Minimum smile *score* (see [smileScore]) to accept [smile].
  ///
  /// ARKit often omits near-zero coefficients from the frame map, and a strong
  /// smile frequently shows up more in cheek-squint / mouth-stretch than in
  /// mouthSmile alone — so the gate uses a combined score, not a single key.
  static const double smileMinScore = 0.15;

  /// Parse a persisted name; unknown / null → [neutral] (legacy manifests).
  static ExpressionMode fromName(String? name) {
    if (name == null || name.isEmpty) {
      return ExpressionMode.neutral;
    }
    for (final ExpressionMode mode in ExpressionMode.values) {
      if (mode.name == name) {
        return mode;
      }
    }
    return ExpressionMode.neutral;
  }

  /// Whether this mode adds a blendshape acceptance gate.
  bool get requiresExpressionGate => this != ExpressionMode.neutral;

  /// Next mode when the user cycles the picker (Neutral ↔ Smile for now).
  ExpressionMode get next => switch (this) {
    ExpressionMode.neutral => ExpressionMode.smile,
    ExpressionMode.smile => ExpressionMode.neutral,
  };

  /// Combined 0–1 smile strength from ARKit coefficients present on the frame.
  static double smileScore(Map<FaceBlendshape, double> blendshapes) {
    double coeff(FaceBlendshape key) => blendshapes[key] ?? 0;

    final double mouthSmile =
        (coeff(FaceBlendshape.mouthSmileLeft) +
            coeff(FaceBlendshape.mouthSmileRight)) /
        2;
    final double cheekSquint =
        (coeff(FaceBlendshape.cheekSquintLeft) +
            coeff(FaceBlendshape.cheekSquintRight)) /
        2;
    final double mouthStretch =
        (coeff(FaceBlendshape.mouthStretchLeft) +
            coeff(FaceBlendshape.mouthStretchRight)) /
        2;
    // Asymmetric smiles: either side alone can be enough.
    final double smileSide = math.max(
      coeff(FaceBlendshape.mouthSmileLeft),
      coeff(FaceBlendshape.mouthSmileRight),
    );

    return math.max(
      math.max(mouthSmile, smileSide),
      math.max(cheekSquint, mouthStretch),
    );
  }

  /// True when [blendshapes] meet this mode's thresholds (always true for neutral).
  bool satisfies(Map<FaceBlendshape, double> blendshapes) {
    switch (this) {
      case ExpressionMode.neutral:
        return true;
      case ExpressionMode.smile:
        return smileScore(blendshapes) >= smileMinScore;
    }
  }

  /// Guidance when pose is fine but the expression gate fails.
  List<PoseGuidance> get missingGuidance => switch (this) {
    ExpressionMode.neutral => const <PoseGuidance>[],
    ExpressionMode.smile => const <PoseGuidance>[PoseGuidance.smileMore],
  };
}
