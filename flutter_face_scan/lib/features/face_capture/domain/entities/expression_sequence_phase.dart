/// Phases of a frontal expression-sequence capture run.
enum ExpressionSequencePhase {
  /// Waiting for Start.
  idle,

  /// Frontal hold while AE/AWB settles, then lock for the whole expression run.
  aeSettle,

  /// Neutral left turn (~40°) still for side texture support.
  supportLeft,

  /// Neutral right turn (~40°) still for side texture support.
  supportRight,

  /// Neutral chin-up still for under-nose / chin gap fill (expression bake).
  supportUp,

  /// Face must be frontal; nothing is persisted yet for the clip.
  settling,

  /// Auto-ready passed; 3–2–1 before buffering.
  countdown,

  /// Ring buffer running; waiting for mimic onset.
  buffering,

  /// Effective start locked; writing until expression+buffer or hard cap.
  recording,

  /// Clip done — frontal hi-res still for the end pose.
  hiResEnd,

  /// Sequence committed to disk.
  completed,

  /// Failed / timed out (e.g. no onset).
  error,
}
