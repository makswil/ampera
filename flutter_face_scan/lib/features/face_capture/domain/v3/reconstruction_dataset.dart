import 'package:vector_math/vector_math_64.dart';

import '../entities/capture_snapshot.dart';
import '../entities/face_pose.dart';

/// ============================================================================
/// V3 — 3D Reconstruction — DATA-STRUCTURE STUB
/// ============================================================================
///
/// Goal: prepare the data structure feeding 3D modelling from the collected
/// `ARFaceAnchor` vertices.
///
/// The V1/V2 capture stages already persist full per-frame vertices inside each
/// [CaptureSnapshot.observation], so reconstruction needs no new capture work —
/// only aggregation + alignment. [ReconstructionDataset] is the hand-off shape;
/// [ReconstructionDatasetBuilder] is the (stubbed) assembler.

/// A per-pose point cloud plus the world transform that placed it.
final class PosePointCloud {
  const PosePointCloud({
    required this.pose,
    required this.vertices,
    required this.worldTransform,
  });

  final FacePose pose;

  /// Vertices in face-anchor local space (metres).
  final List<Vector3> vertices;

  /// Anchor→world transform at capture time (for multi-view alignment).
  final Matrix4 worldTransform;
}

/// Aggregated, reconstruction-ready dataset for one capture session.
final class ReconstructionDataset {
  const ReconstructionDataset({required this.clouds});

  /// One entry per captured pose (frontal / left40 / right40 for V1).
  final List<PosePointCloud> clouds;
}

/// Assembles a [ReconstructionDataset] from captured snapshots.
abstract interface class ReconstructionDatasetBuilder {
  /// Builds the dataset (alignment / merging strategy TBD in V3).
  ReconstructionDataset build(List<CaptureSnapshot> snapshots);
}

/// STUB implementation — wiring deferred to the V3 milestone.
final class DefaultReconstructionDatasetBuilder
    implements ReconstructionDatasetBuilder {
  const DefaultReconstructionDatasetBuilder();

  @override
  ReconstructionDataset build(List<CaptureSnapshot> snapshots) =>
      throw UnimplementedError(
        'V3: align per-pose clouds into a unified model',
      );
}
