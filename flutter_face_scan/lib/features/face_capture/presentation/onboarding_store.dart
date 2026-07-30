import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persists whether the first-time how-to sheet has been shown.
abstract final class OnboardingStore {
  const OnboardingStore._();

  static const String _fileName = '.face_scan_onboarding_seen';

  static Future<File> _file() async {
    final Directory documents = await getApplicationDocumentsDirectory();
    return File('${documents.path}/$_fileName');
  }

  static Future<bool> hasSeen() async {
    try {
      return (await _file()).exists();
    } on Object {
      return false;
    }
  }

  static Future<void> markSeen() async {
    try {
      await (await _file()).writeAsString('1');
    } on Object {
      // Best-effort; onboarding may show again next launch.
    }
  }
}
