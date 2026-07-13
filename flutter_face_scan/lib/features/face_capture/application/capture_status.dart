/// High-level phase of the guided-capture session (the state-machine's modes).
enum CaptureStatus {
  /// Not started yet.
  idle,

  /// Session running, guiding the user through poses.
  capturing,

  /// All poses captured successfully.
  completed,

  /// Tracking/session error.
  error,
}
