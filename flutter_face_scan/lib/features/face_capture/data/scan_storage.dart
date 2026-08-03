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

  /// Short consumer-facing label (no session folder id).
  ///
  /// Prefer [displayName]; otherwise a compact date/time like `3 Aug, 14:32`.
  String get consumerTitle {
    final String? name = displayName?.trim();
    if (name != null && name.isNotEmpty) {
      return name;
    }
    return _consumerDate(modified);
  }

  static String _consumerDate(DateTime d) {
    const List<String> months = <String>[
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime day = DateTime(d.year, d.month, d.day);
    String two(int n) => n.toString().padLeft(2, '0');
    final String time = '${two(d.hour)}:${two(d.minute)}';
    if (day == today) {
      return 'Today, $time';
    }
    if (day == today.subtract(const Duration(days: 1))) {
      return 'Yesterday, $time';
    }
    return '${d.day} ${months[d.month - 1]}, $time';
  }
}

/// One file inside a session folder (non-recursive — bake sits flat next to poses).
final class ScanFileEntry {
  const ScanFileEntry({
    required this.name,
    required this.path,
    required this.sizeBytes,
    required this.modified,
  });

  /// Basename only (e.g. `bake_….obj`).
  final String name;

  /// Absolute path.
  final String path;

  final int sizeBytes;
  final DateTime modified;

  /// Lowercase extension without the leading dot, or empty.
  String get extension {
    final int dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }

  bool get isObj => extension == 'obj';
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

  /// Files directly under the session folder (no subdirs), newest first.
  /// Empty if [id] is missing or unsafe.
  Future<List<ScanFileEntry>> listFiles(String id) async {
    final Directory? dir = SessionPath.sessionDirectory(_scansDir, id);
    if (dir == null || !dir.existsSync()) {
      return const <ScanFileEntry>[];
    }

    final List<ScanFileEntry> files = <ScanFileEntry>[];
    await for (final FileSystemEntity entity in dir.list(followLinks: false)) {
      if (entity is! File) {
        continue;
      }
      final FileStat stat = await entity.stat();
      final String name =
          entity.uri.pathSegments.where((String s) => s.isNotEmpty).last;
      files.add(
        ScanFileEntry(
          name: name,
          path: entity.path,
          sizeBytes: stat.size,
          modified: stat.modified,
        ),
      );
    }
    files.sort(
      (ScanFileEntry a, ScanFileEntry b) => b.modified.compareTo(a.modified),
    );
    return files;
  }

  /// Newest bake `.obj` in the session, or null if none / missing session.
  Future<ScanFileEntry?> newestObj(String id) async {
    final List<ScanFileEntry> files = await listFiles(id);
    for (final ScanFileEntry file in files) {
      if (file.isObj) {
        return file;
      }
    }
    return null;
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
