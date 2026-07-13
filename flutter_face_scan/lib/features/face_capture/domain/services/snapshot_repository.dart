import '../entities/capture_session.dart';
import '../entities/saved_session.dart';

/// Port for persisting a completed capture session.
///
/// The domain depends only on this abstraction; the file-system implementation
/// lives in the data layer, so persistence can be faked/mocked in tests and
/// swapped (e.g. for cloud upload) without touching callers.
abstract interface class SnapshotRepository {
  /// Persists [session] and returns a reference to where it was written.
  Future<SavedSession> save(CaptureSession session);
}
