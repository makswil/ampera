import 'dart:math' as math;

import 'face_blendshape.dart';
import 'pose_guidance.dart';

/// Capture-mode toggle next to Start (bottom-right).
///
/// [neutral] runs the guided 4-pose mesh scan. [smile] runs the frontal
/// expression-sequence capture (settle → countdown → onset → clip).
enum ExpressionMode {
  /// Guided multi-pose scan (frontal → left → right → chin-up).
  neutral(label: 'Pose'),

  /// Frontal expression sequence (rest → any expression), not a hold-gate.
  smile(label: 'Expression');

  const ExpressionMode({required this.label});

  /// Short UI label for pickers (Pose / Expression).
  final String label;

  /// Consumer-facing kind in scan lists and the model viewer.
  String get productLabel => switch (this) {
    ExpressionMode.neutral => '3D model',
    ExpressionMode.smile => 'Expression clip',
  };

  /// Whether this mode runs the frontal expression-sequence flow.
  bool get isExpressionSequence => this == ExpressionMode.smile;

  /// Minimum smile *score* (see [smileScore]) for end-of-sequence / legacy gate.
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

  /// Legacy hold-gate flag — always false; smile is sequence mode now.
  bool get requiresExpressionGate => false;

  /// Next mode when the user cycles the picker (Pose ↔ Expression for now).
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
