import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart';

import '../../domain/entities/capture_session.dart';
import '../../domain/entities/capture_snapshot.dart';
import '../../domain/entities/face_pose.dart';
import '../../domain/entities/still_capture.dart';
import '../../domain/v3/hole_filler.dart';
import '../../domain/v3/texture_projection.dart';
import '../../domain/v3/vertex_normals.dart';
import 'obj_writer.dart';
import 'texture_baker.dart';

/// Result of an in-app bake: the OBJ/MTL/PNG paths written into the session dir.
final class BakedTexture {
  const BakedTexture({
    required this.objPath,
    required this.mtlPath,
    required this.texturePath,
  });

  final String objPath;
  final String mtlPath;
  final String texturePath;
}

/// In-app bake (isolate) from the in-memory [CaptureSession]; writes OBJ+MTL+PNG
/// into the session dir. Same pipeline as `tool/bake_texture.dart`. Null if the
/// three poses / stills aren't all present.
final class SessionTextureBaker {
  const SessionTextureBaker();

  /// Basename = options + timestamp, so every bake is a distinct file (no
  /// overwrite). `smooth` is constant (normals always on in-app).
  static String _baseName({required bool fillHoles, required int textureSize}) {
    final DateTime now = DateTime.now();
    String two(int n) => n.toString().padLeft(2, '0');
    final String ts = '${two(now.hour)}${two(now.minute)}${two(now.second)}'
        '${now.millisecond.toString().padLeft(3, '0')}';
    return <String>[
      'bake',
      'smooth',
      fillHoles ? 'filled' : 'holes',
      '${textureSize}px',
      ts,
    ].join('_');
  }

  Future<BakedTexture?> bake({
    required CaptureSession session,
    required Directory directory,
    bool fillHoles = true,
    int textureSize = 2048,
    bool flipSides = false,
  }) async {
    final String base = _baseName(fillHoles: fillHoles, textureSize: textureSize);
    final _BakeRequest? request = _buildRequest(
      session,
      base: base,
      fillHoles: fillHoles,
      textureSize: textureSize,
      flipSides: flipSides,
    );
    if (request == null) {
      return null;
    }

    final _BakeResult result = await compute(_runBake, request);

    final String pngName = '$base.png';
    final String mtlName = '$base.mtl';
    final File png = File('${directory.path}/$pngName');
    final File mtl = File('${directory.path}/$mtlName');
    final File obj = File('${directory.path}/$base.obj');
    await png.writeAsBytes(result.png);
    await mtl.writeAsString(result.mtl);
    await obj.writeAsString(result.obj);

    return BakedTexture(
      objPath: obj.path,
      mtlPath: mtl.path,
      texturePath: png.path,
    );
  }

  _BakeRequest? _buildRequest(
    CaptureSession session, {
    required String base,
    required bool fillHoles,
    required int textureSize,
    required bool flipSides,
  }) {
    final Map<FacePose, CaptureSnapshot> byPose = <FacePose, CaptureSnapshot>{
      for (final CaptureSnapshot s in session.snapshots) s.pose: s,
    };
    final _PoseInput? frontal =
        _poseInput(byPose[FacePose.frontal], session.stills[FacePose.frontal]);
    final _PoseInput? left =
        _poseInput(byPose[FacePose.left40], session.stills[FacePose.left40]);
    final _PoseInput? right =
        _poseInput(byPose[FacePose.right40], session.stills[FacePose.right40]);
    if (frontal == null || left == null || right == null) {
      return null;
    }

    return _BakeRequest(
      frontal: frontal,
      left40: left,
      right40: right,
      uvs: byPose[FacePose.frontal]!.observation.textureCoordinates,
      triangles: byPose[FacePose.frontal]!.observation.triangleIndices,
      base: base,
      textureSize: textureSize,
      fillHoles: fillHoles,
      flipSides: flipSides,
    );
  }

  _PoseInput? _poseInput(CaptureSnapshot? snapshot, StillCapture? still) {
    if (snapshot == null || still == null || still.bytes.isEmpty) {
      return null;
    }
    return _PoseInput(
      jpeg: still.bytes,
      vertices: snapshot.observation.rawVertices,
      width: still.width,
      height: still.height,
      viewMatrix: still.viewMatrix.storage,
      projectionMatrix: still.projectionMatrix.storage,
      faceTransform: still.faceTransform.storage,
    );
  }
}

/// One pose's bake inputs as isolate-sendable primitives (no `img.Image` /
/// `Matrix4` — decoded/rebuilt inside the isolate).
final class _PoseInput {
  const _PoseInput({
    required this.jpeg,
    required this.vertices,
    required this.width,
    required this.height,
    required this.viewMatrix,
    required this.projectionMatrix,
    required this.faceTransform,
  });

  final Uint8List jpeg;
  final List<double> vertices; // flat [x,y,z, …]
  final int width;
  final int height;
  final List<double> viewMatrix; // 16, column-major
  final List<double> projectionMatrix;
  final List<double> faceTransform;
}

final class _BakeRequest {
  const _BakeRequest({
    required this.frontal,
    required this.left40,
    required this.right40,
    required this.uvs,
    required this.triangles,
    required this.base,
    required this.textureSize,
    required this.fillHoles,
    required this.flipSides,
  });

  final _PoseInput frontal;
  final _PoseInput left40;
  final _PoseInput right40;
  final List<double> uvs;
  final List<int> triangles;
  final String base;
  final int textureSize;
  final bool fillHoles;
  final bool flipSides;
}

final class _BakeResult {
  const _BakeResult({required this.png, required this.obj, required this.mtl});
  final Uint8List png;
  final String obj;
  final String mtl;
}

/// Top-level so it runs in a `compute` isolate. Decodes the JPEGs, bakes the
/// texture, builds smooth normals and renders OBJ/MTL — off the UI thread.
_BakeResult _runBake(_BakeRequest r) {
  BakePose frontal = _toBakePose(r.frontal);
  // Right-turn pose feeds the left face regions by default; flip swaps.
  BakePose leftSource = _toBakePose(r.flipSides ? r.left40 : r.right40);
  BakePose rightSource = _toBakePose(r.flipSides ? r.right40 : r.left40);

  List<double> uvs = r.uvs;
  List<int> triangles = r.triangles;
  List<List<int>> capLoops = const <List<int>>[];
  int capBase = 0;

  // Cap the open eye/mouth holes so they get geometry + texture. Exclude the
  // outer face silhouette (else a giant fan covers the whole mask).
  if (r.fillHoles) {
    final List<List<int>> loops =
        innerHoleLoops(findBoundaryLoops(r.triangles), r.uvs);
    if (loops.isNotEmpty) {
      capBase = r.uvs.length ~/ 2;
      final CapGeometry cap = buildCapGeometry(loops, r.uvs, capBase);
      uvs = <double>[...r.uvs, ...cap.uvs];
      triangles = <int>[...r.triangles, ...cap.triangles];
      frontal = bakePoseWithCaps(frontal, loops);
      leftSource = bakePoseWithCaps(leftSource, loops);
      rightSource = bakePoseWithCaps(rightSource, loops);
      capLoops = loops;
    }
  }

  final img.Image texture = const TextureBaker().bake(
    frontal: frontal,
    left: leftSource,
    right: rightSource,
    uvs: uvs,
    triangles: triangles,
    textureSize: r.textureSize,
  );

  // Normals from the ORIGINAL triangles so cap faces don't crease the rim; then
  // give each cap centroid the mean of its rim normals (smooth seam).
  final List<Vector3> normals =
      computeVertexNormals(frontal.vertices, r.triangles);
  if (capLoops.isNotEmpty) {
    assignCapNormals(normals, capLoops, capBase);
  }

  final String materialName = r.base;
  return _BakeResult(
    png: img.encodePng(texture),
    obj: renderObj(
      vertices: frontal.vertices,
      uvs: uvs,
      normals: normals,
      triangles: triangles,
      materialName: materialName,
      mtlName: '$materialName.mtl',
    ),
    mtl: renderMtl(materialName: materialName, pngName: '$materialName.png'),
  );
}

BakePose _toBakePose(_PoseInput p) {
  final img.Image? image = img.decodeJpg(p.jpeg);
  if (image == null) {
    throw StateError('Could not decode pose JPEG for baking.');
  }
  final List<Vector3> verts = <Vector3>[
    for (int i = 0; i + 2 < p.vertices.length; i += 3)
      Vector3(p.vertices[i], p.vertices[i + 1], p.vertices[i + 2]),
  ];
  return BakePose(
    image: image,
    vertices: verts,
    projection: PoseProjection(
      width: p.width,
      height: p.height,
      viewMatrix: Matrix4.fromList(p.viewMatrix),
      projectionMatrix: Matrix4.fromList(p.projectionMatrix),
      faceTransform: Matrix4.fromList(p.faceTransform),
    ),
  );
}
