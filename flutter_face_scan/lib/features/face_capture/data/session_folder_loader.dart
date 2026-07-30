import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:vector_math/vector_math_64.dart';

import '../domain/entities/capture_session.dart';
import '../domain/entities/capture_snapshot.dart';
import '../domain/entities/euler_angles.dart';
import '../domain/entities/expression_mode.dart';
import '../domain/entities/face_blendshape.dart';
import '../domain/entities/face_observation.dart';
import '../domain/entities/face_pose.dart';
import '../domain/entities/saved_session.dart';
import '../domain/entities/still_capture.dart';

/// Loads a previously saved session folder back into a [CaptureSession] so the
/// in-app baker can re-bake without a new scan. Reads `manifest.json` + PLYs +
/// JPEGs written by [FileSnapshotRepository.save].
final class SessionFolderLoader {
  const SessionFolderLoader();

  /// Newest session under `<documents>/face_scans/`, or null if none / unloadable.
  Future<({CaptureSession session, SavedSession saved})?> loadNewest(
    Directory documents,
  ) async {
    final Directory root = Directory('${documents.path}/face_scans');
    if (!root.existsSync()) {
      return null;
    }
    final List<Directory> dirs = <Directory>[
      await for (final FileSystemEntity e in root.list())
        if (e is Directory) e,
    ];
    if (dirs.isEmpty) {
      return null;
    }
    dirs.sort((Directory a, Directory b) {
      final DateTime am = a.statSync().modified;
      final DateTime bm = b.statSync().modified;
      return bm.compareTo(am);
    });
    for (final Directory dir in dirs) {
      final ({CaptureSession session, SavedSession saved})? loaded =
          await load(dir);
      if (loaded != null) {
        return loaded;
      }
    }
    return null;
  }

  /// Loads one session directory. Null if manifest/stills/mesh incomplete.
  Future<({CaptureSession session, SavedSession saved})?> load(
    Directory dir,
  ) async {
    final File manifestFile = File('${dir.path}/manifest.json');
    if (!manifestFile.existsSync()) {
      return null;
    }
    try {
      final Map<String, dynamic> manifest =
          jsonDecode(await manifestFile.readAsString()) as Map<String, dynamic>;
      final List<double> uvs = _doubles(manifest['textureCoordinates']);
      final List<dynamic> poseRaw = manifest['poses'] as List<dynamic>? ??
          const <dynamic>[];
      if (uvs.isEmpty || poseRaw.isEmpty) {
        return null;
      }

      final List<CaptureSnapshot> snapshots = <CaptureSnapshot>[];
      final Map<FacePose, StillCapture> stills = <FacePose, StillCapture>{};
      final List<String> files = <String>[manifestFile.path];

      for (final dynamic raw in poseRaw) {
        if (raw is! Map) {
          continue;
        }
        final Map<String, dynamic> poseMap = Map<String, dynamic>.from(raw);
        final FacePose? pose = _poseByName(poseMap['pose'] as String?);
        if (pose == null) {
          continue;
        }

        final String? plyName = poseMap['pointCloudFile'] as String?;
        if (plyName == null) {
          continue;
        }
        final File plyFile = File('${dir.path}/$plyName');
        if (!plyFile.existsSync()) {
          continue;
        }
        files.add(plyFile.path);
        final _PlyMesh mesh = _parsePly(await plyFile.readAsString());
        if (mesh.verts.isEmpty) {
          continue;
        }

        final Map<String, dynamic>? euler =
            poseMap['eulerAngles'] as Map<String, dynamic>?;
        final List<double> transform = _doubles(poseMap['transform']);
        snapshots.add(
          CaptureSnapshot(
            pose: pose,
            capturedAt: DateTime.tryParse(poseMap['capturedAt'] as String? ?? '') ??
                DateTime.now(),
            observation: FaceObservation(
              timestamp: Duration.zero,
              isTracked: true,
              eulerAngles: EulerAngles(
                yaw: (euler?['yaw'] as num?)?.toDouble() ?? 0,
                pitch: (euler?['pitch'] as num?)?.toDouble() ?? 0,
                roll: (euler?['roll'] as num?)?.toDouble() ?? 0,
              ),
              rawVertices: mesh.verts,
              blendshapes: const <FaceBlendshape, double>{},
              transformStorage: transform.length == 16
                  ? transform
                  : const <double>[
                      1, 0, 0, 0, //
                      0, 1, 0, 0, //
                      0, 0, 1, 0, //
                      0, 0, 0, 1, //
                    ],
              triangleIndices: mesh.faces,
              // UVs are session-constant; attach to every snapshot (baker reads frontal).
              textureCoordinates: uvs,
            ),
          ),
        );

        final String? imageName = poseMap['imageFile'] as String?;
        final Map<String, dynamic>? stillMap =
            poseMap['still'] as Map<String, dynamic>?;
        if (imageName != null && stillMap != null) {
          final File imageFile = File('${dir.path}/$imageName');
          if (imageFile.existsSync()) {
            files.add(imageFile.path);
            final Uint8List bytes = await imageFile.readAsBytes();
            final List<double> view = _doubles(stillMap['viewMatrix']);
            final List<double> proj = _doubles(stillMap['projectionMatrix']);
            final List<double> face = _doubles(stillMap['faceTransform']);
            if (bytes.isNotEmpty &&
                view.length == 16 &&
                proj.length == 16 &&
                face.length == 16) {
              stills[pose] = StillCapture(
                bytes: bytes,
                width: (stillMap['width'] as num?)?.toInt() ?? 0,
                height: (stillMap['height'] as num?)?.toInt() ?? 0,
                viewMatrix: Matrix4.fromList(view),
                projectionMatrix: Matrix4.fromList(proj),
                faceTransform: Matrix4.fromList(face),
              );
            }
          }
        }
      }

      // Need at least frontal + two sides with stills to bake.
      if (snapshots.isEmpty ||
          stills[FacePose.frontal] == null ||
          stills[FacePose.left40] == null ||
          stills[FacePose.right40] == null) {
        return null;
      }

      final String id = manifest['id'] as String? ??
          dir.uri.pathSegments.where((String s) => s.isNotEmpty).last;
      final DateTime createdAt =
          DateTime.tryParse(manifest['createdAt'] as String? ?? '') ??
              dir.statSync().modified;
      final CaptureSession session = CaptureSession(
        id: id,
        createdAt: createdAt,
        snapshots: snapshots,
        stills: stills,
        expression: ExpressionMode.fromName(
          manifest['expression'] as String?,
        ),
      );
      final SavedSession saved = SavedSession(
        id: id,
        directoryPath: dir.path,
        manifestPath: manifestFile.path,
        files: files,
      );
      return (session: session, saved: saved);
    } on Object {
      return null;
    }
  }

  static FacePose? _poseByName(String? name) {
    if (name == null) {
      return null;
    }
    for (final FacePose p in FacePose.values) {
      if (p.name == name) {
        return p;
      }
    }
    return null;
  }

  static List<double> _doubles(Object? raw) => raw is List
      ? <double>[for (final Object? v in raw) if (v is num) v.toDouble()]
      : const <double>[];
}

final class _PlyMesh {
  const _PlyMesh(this.verts, this.faces);
  final List<double> verts; // flat xyz
  final List<int> faces; // flat triangles
}

/// Minimal ASCII-PLY parser (vertices + optional triangle faces).
_PlyMesh _parsePly(String content) {
  final List<String> lines = content.split('\n');
  int headerEnd = -1;
  int vCount = -1;
  int fCount = 0;
  for (int i = 0; i < lines.length; i++) {
    final String line = lines[i].trim();
    if (line.startsWith('element vertex')) {
      vCount = int.tryParse(line.split(RegExp(r'\s+')).last) ?? -1;
    } else if (line.startsWith('element face')) {
      fCount = int.tryParse(line.split(RegExp(r'\s+')).last) ?? 0;
    }
    if (line == 'end_header') {
      headerEnd = i;
      break;
    }
  }
  if (headerEnd < 0) {
    return const _PlyMesh(<double>[], <int>[]);
  }

  final List<String> data = <String>[
    for (int i = headerEnd + 1; i < lines.length; i++)
      if (lines[i].trim().isNotEmpty) lines[i].trim(),
  ];

  final int vTarget = vCount >= 0 ? vCount : data.length;
  final List<double> verts = <double>[];
  int idx = 0;
  for (; idx < data.length && verts.length < vTarget * 3; idx++) {
    final List<String> parts = data[idx].split(RegExp(r'\s+'));
    if (parts.length < 3) {
      continue;
    }
    final double? x = double.tryParse(parts[0]);
    final double? y = double.tryParse(parts[1]);
    final double? z = double.tryParse(parts[2]);
    if (x != null && y != null && z != null) {
      verts..add(x)..add(y)..add(z);
    }
  }

  final List<int> faces = <int>[];
  for (; idx < data.length && faces.length < fCount * 3; idx++) {
    final List<String> parts = data[idx].split(RegExp(r'\s+'));
    if (parts.length >= 4 && parts[0] == '3') {
      final int? a = int.tryParse(parts[1]);
      final int? b = int.tryParse(parts[2]);
      final int? c = int.tryParse(parts[3]);
      if (a != null && b != null && c != null) {
        faces..add(a)..add(b)..add(c);
      }
    }
  }
  return _PlyMesh(verts, faces);
}
