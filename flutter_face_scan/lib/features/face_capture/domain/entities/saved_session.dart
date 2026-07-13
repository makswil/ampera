import 'package:equatable/equatable.dart';

/// Reference to a persisted [CaptureSession] on disk. Paths are opaque to the
/// domain; the UI uses them to show/share the result.
final class SavedSession extends Equatable {
  const SavedSession({
    required this.id,
    required this.directoryPath,
    required this.manifestPath,
    required this.files,
  });

  /// Session identifier (matches [CaptureSession.id]).
  final String id;

  /// Absolute path of the session folder.
  final String directoryPath;

  /// Absolute path of the JSON manifest.
  final String manifestPath;

  /// All written file paths (manifest + per-pose point clouds).
  final List<String> files;

  @override
  List<Object?> get props => <Object?>[id, directoryPath, manifestPath, files];
}
