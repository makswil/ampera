import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show compute;

import '../domain/entities/capture_session.dart';
import '../domain/entities/capture_snapshot.dart';
import '../domain/entities/face_blendshape.dart';
import '../domain/entities/saved_session.dart';
import '../domain/entities/still_capture.dart';
import '../domain/services/snapshot_repository.dart';
import 'session_path.dart';

/// Writes a [CaptureSession] to the file system: one ASCII-PLY point cloud per
/// pose (face-local vertices, metres) plus a `manifest.json` describing the
/// session (pose, Euler, blendshapes, world transform per snapshot).
///
/// Takes the root [Directory] by injection (not `path_provider`) so it is
/// testable against a temp dir and free of platform plugins.
final class FileSnapshotRepository implements SnapshotRepository {
  const FileSnapshotRepository({required Directory rootDirectory})
    : _root = rootDirectory;

  final Directory _root;

  static const String _manifestName = 'manifest.json';

  @override
  Future<SavedSession> save(CaptureSession session) async {
    final String id = SessionPath.requireSafeSessionId(session.id);
    final Directory dir = Directory('${_root.path}/face_scans/$id');
    await dir.create(recursive: true);

    final List<String> files = <String>[];
    final List<Map<String, Object?>> poseEntries = <Map<String, Object?>>[];

    for (final CaptureSnapshot snapshot in session.snapshots) {
      final String plyName = '${snapshot.pose.name}.ply';
      final File plyFile = File('${dir.path}/$plyName');
      // Encode off the UI isolate: ~1220 vertices/pose of string building would
      // otherwise jank the main thread at completion.
      final String ply = await compute(
        _encodePlyFromRaw,
        (
          verts: snapshot.observation.rawVertices,
          tris: snapshot.observation.triangleIndices,
        ),
      );
      await plyFile.writeAsString(ply);
      files.add(plyFile.path);

      // Per-pose RGB still + its camera projection, if captured (bake epoch).
      String? imageName;
      final StillCapture? still = session.stills[snapshot.pose];
      if (still != null && still.bytes.isNotEmpty) {
        imageName = '${snapshot.pose.name}.jpg';
        final File imageFile = File('${dir.path}/$imageName');
        await imageFile.writeAsBytes(still.bytes);
        files.add(imageFile.path);
      }

      String? rearImageName;
      final StillCapture? rearStill = session.rearStills[snapshot.pose];
      if (rearStill != null && rearStill.bytes.isNotEmpty) {
        rearImageName = '${snapshot.pose.name}_rear.jpg';
        final File rearFile = File('${dir.path}/$rearImageName');
        await rearFile.writeAsBytes(rearStill.bytes);
        files.add(rearFile.path);
      }

      poseEntries.add(
        _poseEntry(snapshot, plyName, imageName, still, rearImageName),
      );
    }

    final bool hasRearPass = session.rearStills.values.any(
      (StillCapture s) => s.bytes.isNotEmpty,
    );
    final Map<String, Object?> manifest = <String, Object?>{
      'id': id,
      'createdAt': session.createdAt.toIso8601String(),
      'schemaVersion': 4,
      'expression': session.expression.name,
      'captureActor': session.actorMode.name,
      'practitionerFlow': session.practitionerFlow.name,
      'meshMotion': session.meshMotion.name,
      'clinicianCamera': session.clinicianCamera.name,
      'rearCaptureKind': session.rearCaptureKind.name,
      if (session.meshRefSessionId != null &&
          SessionPath.isSafeSessionId(session.meshRefSessionId!))
        'meshRefSessionId': session.meshRefSessionId,
      'stabilityProfile': session.stabilityProfile.name,
      'meshPass': <String, Object?>{
        'camera': 'front',
        'meshMotion': session.meshMotion.name,
        if (session.meshRefSessionId != null &&
            SessionPath.isSafeSessionId(session.meshRefSessionId!))
          'refSessionId': session.meshRefSessionId,
      },
      if (hasRearPass)
        'photoPass': <String, Object?>{
          'camera': session.clinicianCamera.name,
          'mode': session.rearCaptureKind.name,
        },
      // Per-vertex UVs (constant across poses) — the bake output layout.
      'textureCoordinates': _textureCoordinates(session),
      'poses': poseEntries,
    };

    final File manifestFile = File('${dir.path}/$_manifestName');
    await manifestFile.writeAsString(
      const JsonEncoder.withIndent('  ').convert(manifest),
    );
    files.add(manifestFile.path);

    return SavedSession(
      id: id,
      directoryPath: dir.path,
      manifestPath: manifestFile.path,
      files: files,
    );
  }

  Map<String, Object?> _poseEntry(
    CaptureSnapshot snapshot,
    String plyName,
    String? imageName,
    StillCapture? still,
    String? rearImageName,
  ) {
    return <String, Object?>{
      'pose': snapshot.pose.name,
      'capturedAt': snapshot.capturedAt.toIso8601String(),
      'vertexCount': snapshot.observation.vertexCount,
      'pointCloudFile': plyName,
      'imageFile': ?imageName,
      'rearImageFile': ?rearImageName,
      'eulerAngles': <String, double>{
        'yaw': snapshot.observation.eulerAngles.yaw,
        'pitch': snapshot.observation.eulerAngles.pitch,
        'roll': snapshot.observation.eulerAngles.roll,
      },
      // Column-major 4x4 face-anchor → world transform (for V3 alignment).
      'transform': snapshot.observation.transformStorage,
      // Camera projection matching the still image (for UV texture baking).
      'still': ?_stillEntry(still),
      'blendshapes': <String, double>{
        for (final MapEntry<FaceBlendshape, double> e
            in snapshot.observation.blendshapes.entries)
          e.key.arkitKey: e.value,
      },
    };
  }

  /// Projection block for the pose's still: image size + the three column-major
  /// matrices that map a face-local vertex into the image. Null when no still.
  Map<String, Object?>? _stillEntry(StillCapture? still) {
    if (still == null) {
      return null;
    }
    return <String, Object?>{
      'width': still.width,
      'height': still.height,
      'viewMatrix': still.viewMatrix.storage.toList(),
      'projectionMatrix': still.projectionMatrix.storage.toList(),
      'faceTransform': still.faceTransform.storage.toList(),
    };
  }

  /// Per-vertex UVs from the first snapshot (constant across poses); empty list
  /// when the backend didn't supply them.
  List<double> _textureCoordinates(CaptureSession session) =>
      session.snapshots.isEmpty
          ? const <double>[]
          : session.snapshots.first.observation.textureCoordinates;
}

/// Builds an ASCII-PLY string from a flat vertex buffer + optional triangle
/// index buffer. Top-level so it can run in a background isolate via `compute`
/// (keeps the UI smooth at save time). Writes a surface mesh when [tris] is
/// non-empty, otherwise a point cloud.
String _encodePlyFromRaw(({List<double> verts, List<int> tris}) job) {
  final List<double> raw = job.verts;
  final List<int> tris = job.tris;
  final int vertexCount = raw.length ~/ 3;
  final int faceCount = tris.length ~/ 3;

  final StringBuffer buffer = StringBuffer()
    ..writeln('ply')
    ..writeln('format ascii 1.0')
    ..writeln('comment flutter_face_scan face-local vertices (metres)')
    ..writeln('element vertex $vertexCount')
    ..writeln('property float x')
    ..writeln('property float y')
    ..writeln('property float z');
  if (faceCount > 0) {
    buffer
      ..writeln('element face $faceCount')
      ..writeln('property list uchar int vertex_indices');
  }
  buffer.writeln('end_header');

  for (int i = 0; i + 2 < raw.length; i += 3) {
    buffer.writeln('${raw[i]} ${raw[i + 1]} ${raw[i + 2]}');
  }
  for (int i = 0; i + 2 < tris.length; i += 3) {
    buffer.writeln('3 ${tris[i]} ${tris[i + 1]} ${tris[i + 2]}');
  }
  return buffer.toString();
}
