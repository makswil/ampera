import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Persists whether the first-time how-to sheet has been shown.
abstract final class OnboardingStore {
  const OnboardingStore._();

  static const String _fileName = '.face_scan_onboarding_seen';
  static const String _smileFileName = '.face_scan_onboarding_seen_smile';

  static Future<File> _file({required bool smile}) async {
    final Directory documents = await getApplicationDocumentsDirectory();
    final String name = smile ? _smileFileName : _fileName;
    return File('${documents.path}/$name');
  }

  static Future<bool> hasSeen({bool smile = false}) async {
    try {
      return (await _file(smile: smile)).exists();
    } on Object {
      return false;
    }
  }

  static Future<void> markSeen({bool smile = false}) async {
    try {
      await (await _file(smile: smile)).writeAsString('1');
    } on Object {
      // Best-effort; onboarding may show again next launch.
    }
  }
}
