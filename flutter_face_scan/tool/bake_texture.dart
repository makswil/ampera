// Dev tool (`dart run`, not part of the app). Bakes a face texture from a saved
// session dir → OBJ + MTL + PNG. Same pipeline as SessionTextureBaker.
//
// Usage:
//   dart run tool/bake_texture.dart <session_dir> [--size=2048] [--flip] \
//       [--no-holes] [--no-normals] [--out=<basename>]
//
//   --flip           swap left/right side source (if cheeks look mirrored).
//   --no-holes       leave ARKit's open eye/mouth holes (default caps them).
//   --no-normals     flat-shaded, no smooth normals (A/B).
//   --view-dependent normal-based (n·v) source selection (else region tables).
//   --best           with --view-dependent: best pose only (no blend, sharper).
//   --no-color-match with --view-dependent: skip matching poses to frontal.

import 'dart:convert';
import 'dart:io';

import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart';

import 'package:flutter_face_scan/features/face_capture/data/bake/obj_writer.dart';
import 'package:flutter_face_scan/features/face_capture/data/bake/texture_baker.dart';
import 'package:flutter_face_scan/features/face_capture/domain/constants/face_vertex_indices.dart';
import 'package:flutter_face_scan/features/face_capture/domain/v3/hole_filler.dart';
import 'package:flutter_face_scan/features/face_capture/domain/v3/texture_projection.dart';
import 'package:flutter_face_scan/features/face_capture/domain/v3/vertex_normals.dart';
import 'package:flutter_face_scan/features/face_capture/domain/v3/view_weights.dart';

void main(List<String> args) {
  final List<String> positional = <String>[];
  int size = 2048;
  bool flip = false;
  bool fillHoles = true;
  bool smoothNormals = true;
  bool viewDependent = false;
  bool bestOnly = false;
  bool colorMatch = true;
  String? out;
  for (final String arg in args) {
    if (arg == '--flip') {
      flip = true;
    } else if (arg == '--no-holes') {
      fillHoles = false;
    } else if (arg == '--no-normals') {
      smoothNormals = false;
    } else if (arg == '--view-dependent') {
      viewDependent = true;
    } else if (arg == '--best') {
      bestOnly = true;
    } else if (arg == '--no-color-match') {
      colorMatch = false;
    } else if (arg.startsWith('--size=')) {
      size = int.tryParse(arg.substring('--size='.length)) ?? size;
    } else if (arg.startsWith('--out=')) {
      out = arg.substring('--out='.length);
    } else if (!arg.startsWith('--')) {
      positional.add(arg);
    }
  }

  // Encode the active options into the basename so variants don't overwrite each
  // other (A/B comparison). Explicit --out wins.
  out ??= <String>[
    'bake',
    smoothNormals ? 'smooth' : 'flat',
    fillHoles ? 'filled' : 'holes',
    if (flip) 'flip',
    if (viewDependent) bestOnly ? 'ndotv-best' : 'ndotv',
    '${size}px',
  ].join('_');
  if (positional.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/bake_texture.dart <session_dir> '
      '[--size=2048] [--flip] [--no-holes] [--no-normals] '
      '[--view-dependent] [--best] [--out=model]',
    );
    exit(64);
  }

  final Directory dir = Directory(positional.first);
  final File manifestFile = File('${dir.path}/manifest.json');
  if (!manifestFile.existsSync()) {
    stderr.writeln('No manifest.json in ${dir.path}');
    exit(66);
  }

  final Map<String, dynamic> manifest =
      jsonDecode(manifestFile.readAsStringSync()) as Map<String, dynamic>;
  final List<double> uvs = _doubles(manifest['textureCoordinates']);
  if (uvs.isEmpty) {
    stderr.writeln('manifest has no textureCoordinates (re-capture with schema '
        'v2). Cannot bake.');
    exit(65);
  }

  final Map<String, Map<String, dynamic>> poses = <String, Map<String, dynamic>>{
    for (final dynamic p in manifest['poses'] as List<dynamic>)
      (p as Map<String, dynamic>)['pose'] as String: p,
  };

  final _Ply frontalPly = _loadPly(dir, poses['frontal']);
  BakePose frontal = _loadPose(dir, poses['frontal'], frontalPly);
  BakePose left40 = _loadPose(dir, poses['left40']);
  BakePose right40 = _loadPose(dir, poses['right40']);
  // Chin-up is optional (older sessions lack it); only used view-dependent.
  BakePose? up = poses['up'] == null ? null : _loadPose(dir, poses['up']);

  List<double> texUvs = uvs;
  List<int> triangles = frontalPly.faces;
  List<List<int>> capLoops = const <List<int>>[];
  int capBase = 0;

  // Cap the open eye/mouth holes so they get geometry + texture. Exclude the
  // outer face silhouette (else a giant fan covers the whole mask).
  if (fillHoles) {
    final List<List<int>> loops =
        innerHoleLoops(findBoundaryLoops(frontalPly.faces), uvs);
    if (loops.isNotEmpty) {
      capBase = uvs.length ~/ 2;
      final CapGeometry cap = buildCapGeometry(loops, uvs, capBase);
      texUvs = <double>[...uvs, ...cap.uvs];
      triangles = <int>[...frontalPly.faces, ...cap.triangles];
      frontal = bakePoseWithCaps(frontal, loops);
      left40 = bakePoseWithCaps(left40, loops);
      right40 = bakePoseWithCaps(right40, loops);
      if (up != null) {
        up = bakePoseWithCaps(up, loops);
      }
      capLoops = loops;
    }
  }

  // Default: right-turn pose feeds the left face regions; --flip swaps.
  final BakePose leftSource = flip ? left40 : right40;
  final BakePose rightSource = flip ? right40 : left40;

  // Normals from the ORIGINAL triangles so cap faces don't crease the rim; cap
  // centroids get the mean of their rim normals. Needed for smooth shading AND
  // the view-dependent weighting.
  List<Vector3> normals = const <Vector3>[];
  if (smoothNormals || viewDependent) {
    normals = computeVertexNormals(frontal.vertices, frontalPly.faces);
    if (capLoops.isNotEmpty) {
      assignCapNormals(normals, capLoops, capBase);
    }
  }

  final img.Image texture = viewDependent
      ? _bakeViewDependent(
          frontal: frontal,
          leftSource: leftSource,
          rightSource: rightSource,
          up: up,
          normals: normals,
          uvs: texUvs,
          triangles: triangles,
          size: size,
          blend: !bestOnly,
          colorMatch: colorMatch,
        )
      : const TextureBaker().bake(
          frontal: frontal,
          left: leftSource,
          right: rightSource,
          uvs: texUvs,
          triangles: triangles,
          textureSize: size,
        );

  // Smooth (Gouraud) shading: only emit normals to the OBJ when requested.
  if (!smoothNormals) {
    normals = const <Vector3>[];
  }

  final String pngName = '$out.png';
  final String mtlName = '$out.mtl';
  File('${dir.path}/$pngName').writeAsBytesSync(img.encodePng(texture));
  File('${dir.path}/$mtlName')
      .writeAsStringSync(renderMtl(materialName: out, pngName: pngName));
  File('${dir.path}/$out.obj').writeAsStringSync(renderObj(
    vertices: frontal.vertices,
    uvs: texUvs,
    normals: normals,
    triangles: triangles,
    materialName: out,
    mtlName: mtlName,
  ));

  stdout
    ..writeln('Baked ${size}×$size texture from '
        '${frontal.vertices.length} verts / '
        '${triangles.length ~/ 3} faces.')
    ..writeln('Wrote ${dir.path}/$out.obj (+ .mtl, .png) — open in MeshLab.');
}

/// View-dependent (`n·v`) bake — mirrors `session_baker._bakeViewDependent`.
img.Image _bakeViewDependent({
  required BakePose frontal,
  required BakePose leftSource,
  required BakePose rightSource,
  required BakePose? up,
  required List<Vector3> normals,
  required List<double> uvs,
  required List<int> triangles,
  required int size,
  required bool blend,
  required bool colorMatch,
}) {
  final FaceGuardFrame frame = computeGuardFrame(
    verts: frontal.vertices,
    symmetryAxis: FaceSymmetryAxis.ordered,
    horizontalAxis: FaceHorizontalAxis.ordered,
  );
  List<double> weightsFor(BakePose pose, PoseGuard guard) => viewFacingWeights(
        faceLocalVerts: pose.vertices,
        localNormals: normals,
        viewMatrix: pose.viewMatrix,
        faceTransform: pose.faceTransform,
        allowed:
            poseAllowMask(verts: frontal.vertices, frame: frame, guard: guard),
      );

  final List<double> wFrontal = weightsFor(frontal, PoseGuard.frontalCenter);
  final List<double> wLeft = weightsFor(leftSource, PoseGuard.leftHalf);
  final List<double> wRight = weightsFor(rightSource, PoseGuard.rightHalf);
  final List<double>? wUp =
      up == null ? null : weightsFor(up, PoseGuard.lowerHalf);

  const TextureBaker baker = TextureBaker();
  List<double> gainFor(BakePose pose, List<double> w) => colorMatch
      ? baker.poseGain(
          reference: frontal,
          pose: pose,
          refWeight: wFrontal,
          poseWeight: w,
        )
      : const <double>[1, 1, 1];

  final List<WeightedPose> weighted = <WeightedPose>[
    WeightedPose(pose: frontal, weight: wFrontal),
    WeightedPose(
        pose: leftSource, weight: wLeft, gain: gainFor(leftSource, wLeft)),
    WeightedPose(
        pose: rightSource, weight: wRight, gain: gainFor(rightSource, wRight)),
    if (up != null && wUp != null)
      WeightedPose(pose: up, weight: wUp, gain: gainFor(up, wUp)),
  ];

  return baker.bakeViewDependent(
    poses: weighted,
    uvs: uvs,
    triangles: triangles,
    textureSize: size,
    blend: blend,
  );
}

BakePose _loadPose(Directory dir, Map<String, dynamic>? pose, [_Ply? preloaded]) {
  if (pose == null) {
    throw StateError('Missing pose in manifest (need frontal/left40/right40).');
  }
  final _Ply ply = preloaded ?? _loadPly(dir, pose);
  final Map<String, dynamic> still = pose['still'] as Map<String, dynamic>? ??
      (throw StateError('Pose ${pose['pose']} has no still projection.'));

  final img.Image? image =
      img.decodeJpg(File('${dir.path}/${pose['imageFile']}').readAsBytesSync());
  if (image == null) {
    throw StateError('Could not decode ${pose['imageFile']}.');
  }

  final Matrix4 viewMatrix = Matrix4.fromList(_doubles(still['viewMatrix']));
  final Matrix4 faceTransform =
      Matrix4.fromList(_doubles(still['faceTransform']));
  return BakePose(
    image: image,
    vertices: ply.verts
        .map((_V3 v) => Vector3(v.x, v.y, v.z))
        .toList(growable: false),
    projection: PoseProjection(
      width: (still['width'] as num).toInt(),
      height: (still['height'] as num).toInt(),
      viewMatrix: viewMatrix,
      projectionMatrix: Matrix4.fromList(_doubles(still['projectionMatrix'])),
      faceTransform: faceTransform,
    ),
    viewMatrix: viewMatrix,
    faceTransform: faceTransform,
  );
}

_Ply _loadPly(Directory dir, Map<String, dynamic>? pose) {
  if (pose == null) {
    throw StateError('Missing pose in manifest.');
  }
  return _parsePly(File('${dir.path}/${pose['pointCloudFile']}').readAsStringSync());
}

List<double> _doubles(Object? raw) => raw is List
    ? <double>[for (final Object? v in raw) if (v is num) v.toDouble()]
    : const <double>[];

/// Minimal ASCII-PLY parser: vertices + flat triangle index buffer.
_Ply _parsePly(String content) {
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
    return const _Ply(<_V3>[], <int>[]);
  }

  final List<String> data = <String>[
    for (int i = headerEnd + 1; i < lines.length; i++)
      if (lines[i].trim().isNotEmpty) lines[i].trim(),
  ];

  final int vTarget = vCount >= 0 ? vCount : data.length;
  final List<_V3> verts = <_V3>[];
  int idx = 0;
  for (; idx < data.length && verts.length < vTarget; idx++) {
    final List<String> parts = data[idx].split(RegExp(r'\s+'));
    if (parts.length < 3) {
      continue;
    }
    final double? x = double.tryParse(parts[0]);
    final double? y = double.tryParse(parts[1]);
    final double? z = double.tryParse(parts[2]);
    if (x != null && y != null && z != null) {
      verts.add(_V3(x, y, z));
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
  return _Ply(verts, faces);
}

class _V3 {
  const _V3(this.x, this.y, this.z);
  final double x;
  final double y;
  final double z;
}

class _Ply {
  const _Ply(this.verts, this.faces);
  final List<_V3> verts;

  /// Flat triangle index buffer `[a0,b0,c0, a1,b1,c1, …]`.
  final List<int> faces;
}
