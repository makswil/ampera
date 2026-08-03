import 'dart:io';

import 'package:flutter_face_scan/features/face_capture/data/session_path.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SessionPath.isSafeSessionId', () {
    test('accepts generated and simple ids', () {
      expect(SessionPath.isSafeSessionId('session_1720000000000'), isTrue);
      expect(SessionPath.isSafeSessionId('scan-a.b_1'), isTrue);
    });

    test('rejects traversal and separators', () {
      expect(SessionPath.isSafeSessionId('../etc'), isFalse);
      expect(SessionPath.isSafeSessionId('a/b'), isFalse);
      expect(SessionPath.isSafeSessionId('..'), isFalse);
      expect(SessionPath.isSafeSessionId(''), isFalse);
      expect(SessionPath.isSafeSessionId('/abs'), isFalse);
    });
  });

  group('SessionPath.fileUnderSession', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('session_path_test');
    });
    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('resolves basename under session root', () {
      final File? file =
          SessionPath.fileUnderSession(tempDir, 'frontal.jpg');
      expect(file, isNotNull);
      expect(file!.path.endsWith('frontal.jpg'), isTrue);
    });

    test('rejects path traversal file names', () {
      expect(SessionPath.fileUnderSession(tempDir, '../secret.jpg'), isNull);
      expect(SessionPath.fileUnderSession(tempDir, 'a/b.jpg'), isNull);
      expect(SessionPath.fileUnderSession(tempDir, '..'), isNull);
    });
  });

  group('SessionPath.sessionDirectory', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('session_path_root');
    });
    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('rejects unsafe ids', () {
      expect(SessionPath.sessionDirectory(tempDir, '../x'), isNull);
      expect(SessionPath.sessionDirectory(tempDir, 'ok_id'), isNotNull);
    });
  });
}
