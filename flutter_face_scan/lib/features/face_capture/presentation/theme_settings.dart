import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Persisted appearance preference. Default is [ThemeMode.system].
class ThemeSettings extends ChangeNotifier {
  ThemeSettings();

  static const String _fileName = '.face_scan_theme_mode';

  ThemeMode _mode = ThemeMode.system;
  bool _loaded = false;

  ThemeMode get mode => _mode;
  bool get loaded => _loaded;

  /// Effective dark preference for a Switch, respecting system when unset.
  bool isDark(Brightness platformBrightness) => switch (_mode) {
        ThemeMode.dark => true,
        ThemeMode.light => false,
        ThemeMode.system => platformBrightness == Brightness.dark,
      };

  /// User override: light or dark. Leaves system only until first toggle.
  void setDark(bool dark) {
    mode = dark ? ThemeMode.dark : ThemeMode.light;
  }

  set mode(ThemeMode value) {
    if (value == _mode) {
      return;
    }
    _mode = value;
    notifyListeners();
    unawaited(_persist());
  }

  Future<void> load() async {
    try {
      final File file = await _file();
      if (await file.exists()) {
        final String raw = (await file.readAsString()).trim();
        _mode = switch (raw) {
          'light' => ThemeMode.light,
          'dark' => ThemeMode.dark,
          _ => ThemeMode.system,
        };
      }
    } on Object {
      _mode = ThemeMode.system;
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _persist() async {
    try {
      final String value = switch (_mode) {
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
        ThemeMode.system => 'system',
      };
      await (await _file()).writeAsString(value);
    } on Object {
      // Best-effort; preference may reset next launch.
    }
  }

  static Future<File> _file() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    return File('${documents.path}/$_fileName');
  }
}
