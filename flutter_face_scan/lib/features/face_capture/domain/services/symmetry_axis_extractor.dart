import '../entities/face_observation.dart';
import '../entities/symmetry_axis.dart';

/// Fits the mid-sagittal symmetry axis from a frame's forehead→chin vertices.
///
/// Abstracted so the fitting strategy (e.g. PCA, total-least-squares) can be
/// swapped or mocked. Implementations MUST be pure (no I/O, deterministic).
abstract interface class SymmetryAxisExtractor {
  /// Returns the fitted axis, or null if the frame is untracked or has too few
  /// usable vertices to fit a line.
  SymmetryAxis? extract(FaceObservation observation);
}
