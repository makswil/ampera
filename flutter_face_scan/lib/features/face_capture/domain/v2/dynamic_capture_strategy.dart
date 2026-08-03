import '../entities/capture_snapshot.dart';
import '../entities/face_blendshape.dart';
import '../entities/face_observation.dart';

/// ============================================================================
/// V2 — Dynamic (expression) Capture — INTERFACE STUB
/// ============================================================================
///
/// Goal: extend V1 with captures under changing facial expressions.
///
/// DESIGN EVALUATION — short video sequences vs. a series of blendshape-keyed
/// snapshots (to be decided before implementation):
///
///   • Snapshot series (RECOMMENDED starting point)
///       - Reuses the V1 pipeline 1:1 — a [FaceObservation] already carries
///         full vertices + blendshapes, so V2 becomes "trigger on blendshape
///         thresholds" instead of "trigger on Euler angle".
///       - Deterministic, sparse, cheap to store, trivially testable.
///       - Each frame is independently usable by V3 reconstruction.
///       - Con: misses transition dynamics between expressions.
///
///   • Video / continuous sequence
///       - Captures temporal dynamics (e.g. dynamic wrinkling, skin slide).
///       - Much larger payload; needs frame selection downstream anyway;
///         harder to unit-test; per-frame vertex export is heavier.
///
///   DECISION HOOK: both are modelled behind [DynamicCaptureStrategy] so the
///   choice is swappable without touching the BLoC. Default to the snapshot
///   series; revisit if reconstruction quality demands temporal data.
///
/// This file intentionally contains only contracts + stubs.
abstract interface class DynamicCaptureStrategy {
  /// Expressions to capture, each with its acceptance trigger.
  List<BlendshapeTarget> get targets;

  /// Returns the [BlendshapeTarget] satisfied by [observation], or null.
  BlendshapeTarget? matchTarget(FaceObservation observation);

  /// True once every target has an accepted snapshot.
  bool isComplete(List<CaptureSnapshot> captured);
}

/// A target expression plus the threshold that accepts it.
final class BlendshapeTarget {
  const BlendshapeTarget({
    required this.shape,
    required this.minCoefficient,
    required this.label,
  });

  final FaceBlendshape shape;
  final double minCoefficient;
  final String label;
}

/// STUB — series of blendshape-keyed snapshots (recommended approach).
final class BlendshapeSnapshotSeriesStrategy implements DynamicCaptureStrategy {
  const BlendshapeSnapshotSeriesStrategy();

  @override
  List<BlendshapeTarget> get targets =>
      throw UnimplementedError('V2: define expression targets');

  @override
  BlendshapeTarget? matchTarget(FaceObservation observation) =>
      throw UnimplementedError('V2: threshold-match blendshapes');

  @override
  bool isComplete(List<CaptureSnapshot> captured) =>
      throw UnimplementedError('V2: completion check');
}
