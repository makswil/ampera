/// On-disk result of a finished expression-sequence capture.
final class ExpressionSequenceResult {
  const ExpressionSequenceResult({
    required this.directoryPath,
    required this.frameCount,
    required this.manifestPath,
  });

  /// Session folder containing `expression/` frames + manifest.
  final String directoryPath;

  /// Number of kept frames after onset trim.
  final int frameCount;

  /// Absolute path to `expression/sequence.json`.
  final String manifestPath;
}
