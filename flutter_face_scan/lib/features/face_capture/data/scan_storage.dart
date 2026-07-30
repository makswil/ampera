import 'dart:convert';
import 'dart:io';

import '../domain/entities/expression_mode.dart';

/// One persisted scan session on disk.
final class ScanEntry {
  const ScanEntry({
    required this.id,
    required this.path,
    required this.modified,
    required this.sizeBytes,
    this.expression = ExpressionMode.neutral,
  });

  /// Folder name (matches [CaptureSession.id]).
  final String id;

  /// Absolute path of the session folder.
  final String path;

  /// Last-modified time of the folder.
  final DateTime modified;

  /// Total size of the folder's files, in bytes.
  final int sizeBytes;

  /// Expression from `manifest.json` (defaults to neutral for legacy sessions).
  final ExpressionMode expression;
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
            expression: await _readExpression(entity),
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

  Future<ExpressionMode> _readExpression(Directory dir) async {
    final File manifest = File('${dir.path}/manifest.json');
    if (!manifest.existsSync()) {
      return ExpressionMode.neutral;
    }
    try {
      final Object? decoded = jsonDecode(await manifest.readAsString());
      if (decoded is Map<String, dynamic>) {
        return ExpressionMode.fromName(decoded['expression'] as String?);
      }
    } on Object {
      // Corrupt / unreadable → treat as neutral.
    }
    return ExpressionMode.neutral;
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
