import 'dart:io';

/// One persisted scan session on disk.
final class ScanEntry {
  const ScanEntry({
    required this.id,
    required this.path,
    required this.modified,
    required this.sizeBytes,
  });

  /// Folder name (matches [CaptureSession.id]).
  final String id;

  /// Absolute path of the session folder.
  final String path;

  /// Last-modified time of the folder.
  final DateTime modified;

  /// Total size of the folder's files, in bytes.
  final int sizeBytes;
}

/// Lists and deletes saved scan sessions under `<root>/face_scans/`.
///
/// Takes the root [Directory] by injection (not `path_provider`) so it stays
/// testable against a temp dir and free of platform plugins.
final class ScanStorage {
  const ScanStorage({required Directory rootDirectory}) : _root = rootDirectory;

  final Directory _root;

  Directory get _scansDir => Directory('${_root.path}/face_scans');

  /// All sessions, newest first. Empty if nothing has been saved.
  Future<List<ScanEntry>> list() async {
    final Directory dir = _scansDir;
    if (!dir.existsSync()) {
      return const <ScanEntry>[];
    }

    final List<ScanEntry> entries = <ScanEntry>[];
    await for (final FileSystemEntity entity in dir.list()) {
      if (entity is Directory) {
        final FileStat stat = await entity.stat();
        entries.add(
          ScanEntry(
            id: entity.uri.pathSegments.where((String s) => s.isNotEmpty).last,
            path: entity.path,
            modified: stat.modified,
            sizeBytes: await _directorySize(entity),
          ),
        );
      }
    }
    entries.sort((ScanEntry a, ScanEntry b) => b.modified.compareTo(a.modified));
    return entries;
  }

  /// Deletes a single session folder by [id]. No-op if it doesn't exist.
  Future<void> delete(String id) async {
    final Directory dir = Directory('${_scansDir.path}/$id');
    if (dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// Deletes every saved session.
  Future<void> deleteAll() async {
    if (_scansDir.existsSync()) {
      await _scansDir.delete(recursive: true);
    }
  }

  Future<int> _directorySize(Directory dir) async {
    int total = 0;
    await for (final FileSystemEntity entity in dir.list(recursive: true)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }
}
