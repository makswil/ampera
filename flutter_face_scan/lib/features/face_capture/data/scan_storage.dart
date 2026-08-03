import 'dart:convert';
import 'dart:io';

import '../domain/entities/expression_mode.dart';
import 'session_path.dart';

/// One persisted scan session on disk.
final class ScanEntry {
  const ScanEntry({
    required this.id,
    required this.path,
    required this.modified,
    required this.sizeBytes,
    this.expression = ExpressionMode.neutral,
    this.displayName,
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

  /// Optional user label from `manifest.json` (`displayName`).
  final String? displayName;

  /// Label for lists: [displayName] when set, otherwise [id].
  String get title {
    final String? name = displayName?.trim();
    if (name == null || name.isEmpty) {
      return id;
    }
    return name;
  }
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
        final _ManifestMeta meta = await _readManifestMeta(entity);
        entries.add(
          ScanEntry(
            id: entity.uri.pathSegments.where((String s) => s.isNotEmpty).last,
            path: entity.path,
            modified: stat.modified,
            sizeBytes: await _directorySize(entity),
            expression: meta.expression,
            displayName: meta.displayName,
          ),
        );
      }
    }
    entries.sort((ScanEntry a, ScanEntry b) => b.modified.compareTo(a.modified));
    return entries;
  }

  /// Deletes a single session folder by [id]. No-op if missing or [id] unsafe.
  Future<void> delete(String id) async {
    final Directory? dir = SessionPath.sessionDirectory(_scansDir, id);
    if (dir != null && dir.existsSync()) {
      await dir.delete(recursive: true);
    }
  }

  /// Deletes every saved session.
  Future<void> deleteAll() async {
    if (_scansDir.existsSync()) {
      await _scansDir.delete(recursive: true);
    }
  }

  /// Sets or clears the session's display name in `manifest.json`.
  ///
  /// Empty / whitespace [displayName] removes the field (UI falls back to [id]).
  /// Folder id stays unchanged so Prior-mesh refs keep working.
  Future<void> rename(String id, String displayName) async {
    final Directory? dir = SessionPath.sessionDirectory(_scansDir, id);
    if (dir == null) {
      return;
    }
    final File manifest = File('${dir.path}/manifest.json');
    if (!manifest.existsSync()) {
      return;
    }
    try {
      final Object? decoded = jsonDecode(await manifest.readAsString());
      if (decoded is! Map<String, dynamic>) {
        return;
      }
      final String trimmed = displayName.trim();
      if (trimmed.isEmpty) {
        decoded.remove('displayName');
      } else {
        decoded['displayName'] = trimmed;
      }
      await manifest.writeAsString(
        const JsonEncoder.withIndent('  ').convert(decoded),
      );
    } on Object {
      // Corrupt / unreadable → leave as-is.
    }
  }

  Future<_ManifestMeta> _readManifestMeta(Directory dir) async {
    final File manifest = File('${dir.path}/manifest.json');
    if (!manifest.existsSync()) {
      return const _ManifestMeta();
    }
    try {
      final Object? decoded = jsonDecode(await manifest.readAsString());
      if (decoded is Map<String, dynamic>) {
        final String? rawName = decoded['displayName'] as String?;
        final String? name = rawName?.trim();
        return _ManifestMeta(
          expression: ExpressionMode.fromName(decoded['expression'] as String?),
          displayName: (name == null || name.isEmpty) ? null : name,
        );
      }
    } on Object {
      // Corrupt / unreadable → defaults.
    }
    return const _ManifestMeta();
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

final class _ManifestMeta {
  const _ManifestMeta({
    this.expression = ExpressionMode.neutral,
    this.displayName,
  });

  final ExpressionMode expression;
  final String? displayName;
}
