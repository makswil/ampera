import 'dart:io';

/// Path hygiene for on-disk session folders under `face_scans/`.
///
/// Session ids and manifest-relative file names are treated as untrusted:
/// a crafted `manifest.json` or `meshRefSessionId` must not escape the
/// session / scans root via `..`, absolute paths, or separators.
abstract final class SessionPath {
  /// Folder-name / session-id pattern: alphanumeric start, then safe chars.
  /// Matches generated ids (`session_<epoch>`) and typical user labels.
  static final RegExp _safeId = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$');

  /// True when [id] is safe to interpolate under `face_scans/<id>/`.
  static bool isSafeSessionId(String id) {
    if (id.isEmpty || id.contains('/') || id.contains(r'\')) {
      return false;
    }
    if (id == '.' || id == '..' || id.contains('..')) {
      return false;
    }
    return _safeId.hasMatch(id);
  }

  /// Returns [id] or throws [ArgumentError] when unsafe.
  static String requireSafeSessionId(String id) {
    if (!isSafeSessionId(id)) {
      throw ArgumentError.value(id, 'id', 'unsafe session id');
    }
    return id;
  }

  /// Basename-only file name safe to join under a session directory.
  static bool isSafeRelativeFileName(String name) {
    if (name.isEmpty || name.contains('/') || name.contains(r'\')) {
      return false;
    }
    if (name == '.' || name == '..' || name.contains('..')) {
      return false;
    }
    // Reject absolute / drive-style names on any platform.
    if (name.startsWith('/') || RegExp(r'^[A-Za-z]:').hasMatch(name)) {
      return false;
    }
    return true;
  }

  /// Resolves [name] under [sessionDir]. Null if [name] is unsafe or the
  /// resolved path would escape [sessionDir] (symlink / `..` edge cases).
  static File? fileUnderSession(Directory sessionDir, String name) {
    if (!isSafeRelativeFileName(name)) {
      return null;
    }
    final String sessionRoot = _canonicalize(sessionDir.path);
    final File candidate = File('$sessionRoot${Platform.pathSeparator}$name');
    final String resolved = _canonicalize(candidate.path);
    if (!_isWithinRoot(resolved, sessionRoot)) {
      return null;
    }
    return File(resolved);
  }

  /// Session folder under `face_scans/`. Null when [id] is unsafe.
  static Directory? sessionDirectory(Directory scansRoot, String id) {
    if (!isSafeSessionId(id)) {
      return null;
    }
    final String root = _canonicalize(scansRoot.path);
    final Directory dir = Directory('$root${Platform.pathSeparator}$id');
    final String resolved = _canonicalize(dir.path);
    if (!_isWithinRoot(resolved, root)) {
      return null;
    }
    return Directory(resolved);
  }

  static String _canonicalize(String path) {
    // Prefer real path when the node exists; otherwise normalize lexically.
    try {
      return File(path).resolveSymbolicLinksSync();
    } on FileSystemException {
      return _normalizeLexical(path);
    }
  }

  static String _normalizeLexical(String path) {
    final String sep = Platform.pathSeparator;
    final List<String> parts = <String>[];
    for (final String part in path.split(RegExp(r'[/\\]'))) {
      if (part.isEmpty || part == '.') {
        continue;
      }
      if (part == '..') {
        if (parts.isNotEmpty) {
          parts.removeLast();
        }
        continue;
      }
      parts.add(part);
    }
    final bool absolute = path.startsWith('/') ||
        (Platform.isWindows && RegExp(r'^[A-Za-z]:').hasMatch(path));
    if (absolute && !Platform.isWindows) {
      return '/${parts.join(sep)}';
    }
    return parts.join(sep);
  }

  static bool _isWithinRoot(String path, String root) {
    if (path == root) {
      return true;
    }
    final String prefix = root.endsWith(Platform.pathSeparator)
        ? root
        : '$root${Platform.pathSeparator}';
    return path.startsWith(prefix);
  }
}
