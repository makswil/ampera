import 'dart:io';

import 'package:flutter_face_scan/features/face_capture/data/scan_storage.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/expression_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('scan_storage_test');
  });
  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  Future<void> makeSession(
    String id, {
    int bytes = 10,
    String? expression,
  }) async {
    final Directory dir = Directory('${tempDir.path}/face_scans/$id');
    await dir.create(recursive: true);
    await File('${dir.path}/frontal.ply').writeAsString('x' * bytes);
    final String expressionField =
        expression == null ? '' : ',\n  "expression": "$expression"';
    await File('${dir.path}/manifest.json').writeAsString(
      '{\n  "id": "$id"$expressionField\n}',
    );
  }

  test('lists nothing when no scans exist', () async {
    final ScanStorage storage = ScanStorage(rootDirectory: tempDir);
    expect(await storage.list(), isEmpty);
  });

  test('lists saved sessions with id and non-zero size', () async {
    await makeSession('session_a', bytes: 100);
    await makeSession('session_b', bytes: 50);

    final ScanStorage storage = ScanStorage(rootDirectory: tempDir);
    final List<ScanEntry> entries = await storage.list();

    expect(entries.map((ScanEntry e) => e.id), containsAll(<String>[
      'session_a',
      'session_b',
    ]));
    expect(entries.every((ScanEntry e) => e.sizeBytes > 0), isTrue);
    expect(
      entries.every((ScanEntry e) => e.expression == ExpressionMode.neutral),
      isTrue,
    );
  });

  test('reads expression from the manifest', () async {
    await makeSession('session_smile', expression: 'smile');

    final ScanStorage storage = ScanStorage(rootDirectory: tempDir);
    final List<ScanEntry> entries = await storage.list();

    expect(entries.single.expression, ExpressionMode.smile);
  });

  test('renames via displayName without changing folder id', () async {
    await makeSession('session_a');
    final ScanStorage storage = ScanStorage(rootDirectory: tempDir);

    await storage.rename('session_a', '  Patient left  ');
    ScanEntry entry = (await storage.list()).single;
    expect(entry.id, 'session_a');
    expect(entry.displayName, 'Patient left');
    expect(entry.title, 'Patient left');

    await storage.rename('session_a', '   ');
    entry = (await storage.list()).single;
    expect(entry.displayName, isNull);
    expect(entry.title, 'session_a');
  });

  test('ignores unsafe delete ids (path traversal)', () async {
    await makeSession('session_a');
    final ScanStorage storage = ScanStorage(rootDirectory: tempDir);

    await storage.delete('../session_a');
    await storage.delete('session_a/../session_a');

    expect(
      (await storage.list()).map((ScanEntry e) => e.id),
      <String>['session_a'],
    );
  });

  test('deletes a single session', () async {
    await makeSession('session_a');
    await makeSession('session_b');
    final ScanStorage storage = ScanStorage(rootDirectory: tempDir);

    await storage.delete('session_a');

    final List<String> ids =
        (await storage.list()).map((ScanEntry e) => e.id).toList();
    expect(ids, <String>['session_b']);
  });

  test('deletes all sessions', () async {
    await makeSession('session_a');
    await makeSession('session_b');
    final ScanStorage storage = ScanStorage(rootDirectory: tempDir);

    await storage.deleteAll();

    expect(await storage.list(), isEmpty);
  });
}
