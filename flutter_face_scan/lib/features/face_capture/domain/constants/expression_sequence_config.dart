import '../entities/face_pose.dart';

/// Timing and thresholds for frontal expression-sequence capture.
abstract final class ExpressionSequenceConfig {
  /// Soft neutral band while learning the smile baseline in the buffer phase.
  static const double readyNeutralMaxSmile = 0.12;

  /// Brief on-target debounce before the countdown (countdown is the hold).
  static const Duration readyHold = Duration(milliseconds: 250);

  /// Countdown after settle, before capture buffering starts.
  static const Duration countdown = Duration(seconds: 3);

  /// Include this much time before detected mimic motion.
  static const Duration onsetLookback = Duration(seconds: 1);

  /// Smile-score rise over baseline that counts as mimic onset.
  /// Kept high enough that resting faces don't false-trigger.
  static const double onsetDelta = 0.15;

  /// Absolute smile score that also counts as onset.
  static const double onsetAbsolute = 0.22;

  /// Minimum kept-clip length once onset is locked.
  static const Duration recordDurationMin = Duration(seconds: 3);

  /// Absolute max clip length (even if mimic is still moving).
  static const Duration recordDurationMax = Duration(seconds: 10);

  /// After [recordDurationMin], stop once smile score stays within this range
  /// for [mimicStableFor] — ignores small wiggles.
  static const double mimicChangeEpsilon = 0.08;

  /// How long the smile score must stay "flat" (within [mimicChangeEpsilon])
  /// after the minimum duration before we cut.
  static const Duration mimicStableFor = Duration(milliseconds: 800);

  /// Abort if no mimic onset after countdown within this window.
  static const Duration noOnsetTimeout = Duration(seconds: 15);

  /// Target sample rate while buffering / recording (default).
  /// Overridable via Dev settings (1–60); ARKit can deliver up to ~60 fps.
  static const double targetFps = 20;

  static const int minFps = 1;
  static const int maxFps = 60;

  /// Hold time for each neutral support still (L / R / chin-up) before capture.
  static const Duration supportHold = Duration(milliseconds: 1200);

  /// Frontal hold before AE/AWB settle+lock (then support stills + clip).
  static const Duration aeSettleHold = Duration(milliseconds: 800);

  /// Capture order for texture support stills (before expression settle).
  /// Frontal is the clip itself (~20 fps). Chin-up fills under-chin / nostrils.
  static const List<FacePose> supportPoses = <FacePose>[
    FacePose.left40,
    FacePose.right40,
    FacePose.up,
  ];
}
