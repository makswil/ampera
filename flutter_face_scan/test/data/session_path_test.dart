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

  group('SessionPath.fileUnderRoot', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('session_path_nested');
    });
    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('allows nested relative paths under root', () {
      final File? file =
          SessionPath.fileUnderRoot(tempDir, 'frames/0001.jpg');
      expect(file, isNotNull);
      expect(file!.path.contains('frames'), isTrue);
      expect(file.path.endsWith('0001.jpg'), isTrue);
    });

    test('rejects traversal in nested relative paths', () {
      expect(
        SessionPath.fileUnderRoot(tempDir, 'frames/../secret.jpg'),
        isNull,
      );
      expect(SessionPath.fileUnderRoot(tempDir, '../x.jpg'), isNull);
      expect(SessionPath.fileUnderRoot(tempDir, '/abs.jpg'), isNull);
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

  group('SessionPath face_scans absolute allowlist', () {
    test('isUnderFaceScansTree requires face_scans/<safeId>', () {
      expect(
        SessionPath.isUnderFaceScansTree(
          '/tmp/docs/face_scans/session_1/expression',
        ),
        isTrue,
      );
      expect(
        SessionPath.isUnderFaceScansTree('/tmp/docs/other/session_1'),
        isFalse,
      );
      expect(
        SessionPath.isUnderFaceScansTree('/tmp/docs/face_scans/../etc'),
        isFalse,
      );
    });

    test('isExpressionSequenceManifestPath checks layout', () {
      expect(
        SessionPath.isExpressionSequenceManifestPath(
          '/tmp/docs/face_scans/session_1/expression/sequence.json',
        ),
        isTrue,
      );
      expect(
        SessionPath.isExpressionSequenceManifestPath(
          '/tmp/docs/face_scans/session_1/sequence.json',
        ),
        isFalse,
      );
      expect(
        SessionPath.isExpressionSequenceManifestPath(
          '/tmp/docs/face_scans/../evil/expression/sequence.json',
        ),
        isFalse,
      );
    });

    test('sessionIdFromExpressionManifest extracts id', () {
      expect(
        SessionPath.sessionIdFromExpressionManifest(
          '/tmp/docs/face_scans/session_abc/expression/sequence.json',
        ),
        'session_abc',
      );
      expect(
        SessionPath.sessionIdFromExpressionManifest('/tmp/x/sequence.json'),
        isNull,
      );
    });
  });
}
