import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_face_scan/features/face_capture/data/file_snapshot_repository.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/capture_session.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/capture_snapshot.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/euler_angles.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/face_pose.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/saved_session.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/still_capture.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

import '../support/face_observation_fixtures.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('face_scan_test');
  });
  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  CaptureSnapshot snapshotFor(FacePose pose) {
    return CaptureSnapshot(
      pose: pose,
      observation: observationOnLine(eulerAngles: const EulerAngles.zero()),
      capturedAt: DateTime(2026, 1, 1),
    );
  }

  test('writes a manifest + one PLY per pose and returns their paths', () async {
    final FileSnapshotRepository repository = FileSnapshotRepository(
      rootDirectory: tempDir,
    );
    final CaptureSession session = CaptureSession(
      id: 'session_test',
      createdAt: DateTime(2026, 1, 1),
      snapshots: <CaptureSnapshot>[
        snapshotFor(FacePose.frontal),
        snapshotFor(FacePose.left40),
        snapshotFor(FacePose.right40),
      ],
    );

    final SavedSession saved = await repository.save(session);

    // Manifest + 3 PLYs.
    expect(saved.files.length, 4);
    expect(File(saved.manifestPath).existsSync(), isTrue);
    expect(
      File('${saved.directoryPath}/frontal.ply').existsSync(),
      isTrue,
    );

    final Map<String, dynamic> manifest =
        jsonDecode(await File(saved.manifestPath).readAsString())
            as Map<String, dynamic>;
    expect(manifest['id'], 'session_test');
    final List<dynamic> poses = manifest['poses'] as List<dynamic>;
    expect(poses.length, 3);
    expect((poses.first as Map<String, dynamic>)['pose'], 'frontal');
    expect(
      (poses.first as Map<String, dynamic>)['vertexCount'],
      kFaceVertexCount,
    );
    expect(
      (poses.first as Map<String, dynamic>)['transform'],
      hasLength(16),
    );
  });

  test('PLY has a valid header and one line per vertex', () async {
    final FileSnapshotRepository repository = FileSnapshotRepository(
      rootDirectory: tempDir,
    );
    final SavedSession saved = await repository.save(
      CaptureSession(
        id: 'session_ply',
        createdAt: DateTime(2026, 1, 1),
        snapshots: <CaptureSnapshot>[snapshotFor(FacePose.frontal)],
      ),
    );

    final List<String> lines = await File('${saved.directoryPath}/frontal.ply')
        .readAsLines();
    expect(lines.first, 'ply');
    expect(lines, contains('element vertex $kFaceVertexCount'));
    expect(lines, isNot(contains('element face 0')));
    final int headerEnd = lines.indexOf('end_header');
    expect(headerEnd, greaterThan(0));
    expect(lines.length - headerEnd - 1, kFaceVertexCount);
  });

  test('writes a surface mesh (faces) when triangle topology is present',
      () async {
    final FileSnapshotRepository repository = FileSnapshotRepository(
      rootDirectory: tempDir,
    );
    // Two triangles referencing valid vertex indices.
    final CaptureSnapshot snapshot = CaptureSnapshot(
      pose: FacePose.frontal,
      observation: observationOnLine(
        eulerAngles: const EulerAngles.zero(),
        triangleIndices: const <int>[0, 1, 2, 2, 3, 0],
      ),
      capturedAt: DateTime(2026, 1, 1),
    );
    final SavedSession saved = await repository.save(
      CaptureSession(
        id: 'session_mesh',
        createdAt: DateTime(2026, 1, 1),
        snapshots: <CaptureSnapshot>[snapshot],
      ),
    );

    final List<String> lines = await File('${saved.directoryPath}/frontal.ply')
        .readAsLines();
    expect(lines, contains('element face 2'));
    expect(lines, contains('3 0 1 2'));
    expect(lines, contains('3 2 3 0'));
  });

  test('writes per-pose stills + projection and references them in the manifest',
      () async {
    final FileSnapshotRepository repository = FileSnapshotRepository(
      rootDirectory: tempDir,
    );
    final SavedSession saved = await repository.save(
      CaptureSession(
        id: 'session_img',
        createdAt: DateTime(2026, 1, 1),
        snapshots: <CaptureSnapshot>[snapshotFor(FacePose.frontal)],
        stills: <FacePose, StillCapture>{
          FacePose.frontal: StillCapture(
            bytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
            width: 720,
            height: 1280,
            viewMatrix: Matrix4.identity(),
            projectionMatrix: Matrix4.identity(),
            faceTransform: Matrix4.identity(),
          ),
        },
      ),
    );

    final File image = File('${saved.directoryPath}/frontal.jpg');
    expect(image.existsSync(), isTrue);
    expect(await image.readAsBytes(), <int>[1, 2, 3, 4]);

    final Map<String, dynamic> manifest =
        jsonDecode(await File(saved.manifestPath).readAsString())
            as Map<String, dynamic>;
    final Map<String, dynamic> pose =
        (manifest['poses'] as List<dynamic>).first as Map<String, dynamic>;
    expect(pose['imageFile'], 'frontal.jpg');
    final Map<String, dynamic> still = pose['still'] as Map<String, dynamic>;
    expect(still['width'], 720);
    expect(still['height'], 1280);
    expect((still['viewMatrix'] as List<dynamic>).length, 16);
    expect((still['projectionMatrix'] as List<dynamic>).length, 16);
    expect((still['faceTransform'] as List<dynamic>).length, 16);
  });
}
