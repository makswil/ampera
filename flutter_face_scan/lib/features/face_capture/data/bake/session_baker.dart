import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart';

import '../../domain/constants/face_regions.g.dart';
import '../../domain/constants/face_vertex_indices.dart';
import '../../domain/entities/capture_session.dart';
import '../../domain/entities/capture_snapshot.dart';
import '../../domain/entities/face_pose.dart';
import '../../domain/entities/still_capture.dart';
import '../../domain/v3/hole_filler.dart';
import '../../domain/v3/texture_projection.dart';
import '../../domain/v3/vertex_normals.dart';
import '../../domain/v3/view_weights.dart';
import 'obj_writer.dart';
import 'texture_baker.dart';

/// The chin-up source ramps in between these fractions of the axis→chin
/// distance (0 = at the horizontal axis, 1 = at the chin):
///  * [_downStartFraction] — dead-zone below the axis kept on the FRONTAL source.
///    The (lower) nose sits just under the axis and the chin-up view
///    foreshortens/occludes it, so including it ghosts a "second nose" onto the
///    upper lip. Start below it.
///  * [_downFullFraction] — where the chin-up source reaches full weight.
/// Tune on-device against the baked result (larger start = safer for the nose,
/// but less under-nose coverage).
const double _downStartFraction = 0.25;
const double _downFullFraction = 0.60;

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

  /// Resolves a requested texture size. `> 0` is used as-is; `<= 0` (Original)
  /// becomes the frontal still's larger dimension, clamped to [512, 8192].
  static int _resolveTextureSize(int requested, CaptureSession session) {
    if (requested > 0) {
      return requested;
    }
    final StillCapture? frontal = session.stills[FacePose.frontal];
    final int src = frontal == null ? 0 : math.max(frontal.width, frontal.height);
    return src <= 0 ? 2048 : src.clamp(512, 8192);
  }

  Future<BakedTexture?> bake({
    required CaptureSession session,
    required Directory directory,
    bool fillHoles = true,
    int textureSize = 2048,
    bool flipSides = false,
    bool useChinUp = true,
    bool viewDependent = false,
    bool viewBlend = true,
    bool colorMatch = true,
    bool colorMatchNeutral = false,
  }) async {
    // textureSize 0 = Original: match the frontal still's larger dimension
    // (clamped), so the atlas isn't the bottleneck.
    final int resolved = _resolveTextureSize(textureSize, session);
    final String base = _baseName(fillHoles: fillHoles, textureSize: resolved);
    final _BakeRequest? request = _buildRequest(
      session,
      base: base,
      fillHoles: fillHoles,
      textureSize: resolved,
      flipSides: flipSides,
      useChinUp: useChinUp,
      viewDependent: viewDependent,
      viewBlend: viewBlend,
      colorMatch: colorMatch,
      colorMatchNeutral: colorMatchNeutral,
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
    required bool useChinUp,
    required bool viewDependent,
    required bool viewBlend,
    required bool colorMatch,
    required bool colorMatchNeutral,
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

    // The chin-up pose is optional: older sessions (captured before it existed)
    // still bake — the under-face just falls back to the frontal source. Also
    // skipped entirely when [useChinUp] is off (A/B / fallback).
    final _PoseInput? up = useChinUp
        ? _poseInput(byPose[FacePose.up], session.stills[FacePose.up])
        : null;

    return _BakeRequest(
      frontal: frontal,
      left40: left,
      right40: right,
      up: up,
      uvs: byPose[FacePose.frontal]!.observation.textureCoordinates,
      triangles: byPose[FacePose.frontal]!.observation.triangleIndices,
      base: base,
      textureSize: textureSize,
      fillHoles: fillHoles,
      flipSides: flipSides,
      viewDependent: viewDependent,
      viewBlend: viewBlend,
      colorMatch: colorMatch,
      colorMatchNeutral: colorMatchNeutral,
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
    required this.up,
    required this.uvs,
    required this.triangles,
    required this.base,
    required this.textureSize,
    required this.fillHoles,
    required this.flipSides,
    required this.viewDependent,
    required this.viewBlend,
    required this.colorMatch,
    required this.colorMatchNeutral,
  });

  final _PoseInput frontal;
  final _PoseInput left40;
  final _PoseInput right40;
  final _PoseInput? up;
  final List<double> uvs;
  final List<int> triangles;
  final String base;
  final int textureSize;
  final bool fillHoles;
  final bool flipSides;
  final bool viewDependent;
  final bool viewBlend;
  final bool colorMatch;
  final bool colorMatchNeutral;
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
  BakePose? upSource = r.up == null ? null : _toBakePose(r.up!);

  // Per-vertex chin-up blend weight, from the ORIGINAL (pre-cap) frontal
  // geometry so cap vertices stay 0 (frontal). Only the static path uses it;
  // empty in view-dependent mode or when there's no up pose.
  final List<double> downWeight = (r.viewDependent || upSource == null)
      ? const <double>[]
      : _computeDownWeights(frontal.vertices);

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
      if (upSource != null) {
        upSource = bakePoseWithCaps(upSource, loops);
      }
      capLoops = loops;
    }
  }

  // Normals from the ORIGINAL triangles so cap faces don't crease the rim; then
  // give each cap centroid the mean of its rim normals (smooth seam). Computed
  // before the bake so the view-dependent path can weight by them too.
  final List<Vector3> normals =
      computeVertexNormals(frontal.vertices, r.triangles);
  if (capLoops.isNotEmpty) {
    assignCapNormals(normals, capLoops, capBase);
  }

  final img.Image texture = r.viewDependent
      ? _bakeViewDependent(
          frontal: frontal,
          leftSource: leftSource,
          rightSource: rightSource,
          upSource: upSource,
          normals: normals,
          uvs: uvs,
          triangles: triangles,
          textureSize: r.textureSize,
          blend: r.viewBlend,
          colorMatch: r.colorMatch,
          colorMatchNeutral: r.colorMatchNeutral,
        )
      : const TextureBaker().bake(
          frontal: frontal,
          left: leftSource,
          right: rightSource,
          up: upSource,
          downWeight: downWeight,
          uvs: uvs,
          triangles: triangles,
          textureSize: r.textureSize,
        );

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

/// Per-vertex weight (0..1) for pulling colour from the chin-up still.
///
/// The horizontal axis' mean height is the upper/lower boundary; below it the
/// weight ramps up toward the chin. It's scaled by `(1 - sideWeight)` so the
/// cheeks/jaw keep their left/right side source and only the centre under-face
/// (under-nose, philtrum, lips, chin) switches to the chin-up view. `[verts]`
/// are the ORIGINAL (pre-cap) face-local frontal vertices.
List<double> _computeDownWeights(List<Vector3> verts) {
  final List<double> out = List<double>.filled(verts.length, 0);

  double sum = 0;
  int n = 0;
  for (final int i in FaceHorizontalAxis.ordered) {
    if (i >= 0 && i < verts.length) {
      sum += verts[i].y;
      n++;
    }
  }
  if (n == 0) {
    return out;
  }
  final double midY = sum / n;

  final int chin = FaceSymmetryAxis.chinVertex;
  final double chinY =
      (chin >= 0 && chin < verts.length) ? verts[chin].y : midY;
  final double span = midY - chinY;
  if (span <= 0) {
    return out;
  }

  for (int i = 0; i < verts.length; i++) {
    // t: 0 at the horizontal axis, 1 at the chin (y is up, so lower = smaller y).
    final double t = (midY - verts[i].y) / span;
    final double ramp = ((t - _downStartFraction) /
            (_downFullFraction - _downStartFraction))
        .clamp(0.0, 1.0);
    final double side =
        (i < FaceRegions.sideWeight.length) ? FaceRegions.sideWeight[i] : 0;
    out[i] = ramp * (1 - side);
  }
  return out;
}

/// View-dependent (normal-based) bake: each pose contributes per vertex by how
/// head-on it saw the surface (`n·v`), gated by a per-pose spatial guard so a
/// pose never bleeds across the symmetry axis. Replaces the static
/// `sideWeight`/`downWeight` tables. `[normals]` are the canonical face-local
/// normals (incl. cap centroids), index-aligned with each pose's vertices.
///
/// Guard mapping (see `view_weights.dart`):
///  * frontal   → central band only (turn poses own the outer face),
///  * leftSource (turn-right pose) → left half (negative local X),
///  * rightSource (turn-left pose) → right half (positive local X),
///  * upSource (chin-up pose) → lower half (below the horizontal axis).
img.Image _bakeViewDependent({
  required BakePose frontal,
  required BakePose leftSource,
  required BakePose rightSource,
  required BakePose? upSource,
  required List<Vector3> normals,
  required List<double> uvs,
  required List<int> triangles,
  required int textureSize,
  required bool blend,
  required bool colorMatch,
  required bool colorMatchNeutral,
}) {
  final FaceGuardFrame frame = computeGuardFrame(
    verts: frontal.vertices,
    symmetryAxis: FaceSymmetryAxis.ordered,
    horizontalAxis: FaceHorizontalAxis.ordered,
  );

  // Spatial guards from the canonical (frontal) geometry, shared across poses.
  final List<bool> allowFrontal = poseAllowMask(
      verts: frontal.vertices, frame: frame, guard: PoseGuard.frontalCenter);
  final List<bool> allowLeft = poseAllowMask(
      verts: frontal.vertices, frame: frame, guard: PoseGuard.leftHalf);
  final List<bool> allowRight = poseAllowMask(
      verts: frontal.vertices, frame: frame, guard: PoseGuard.rightHalf);
  final List<bool> allowLower = poseAllowMask(
      verts: frontal.vertices, frame: frame, guard: PoseGuard.lowerHalf);

  List<double> weightsFor(BakePose pose, List<bool> allowed) => viewFacingWeights(
        faceLocalVerts: pose.vertices,
        localNormals: normals,
        viewMatrix: pose.viewMatrix,
        faceTransform: pose.faceTransform,
        allowed: allowed,
      );

  // Poses in order (frontal first → reference + fallback). Only present ones.
  final List<BakePose> orderedPoses = <BakePose>[
    frontal,
    leftSource,
    rightSource,
    ?upSource,
  ];
  final List<List<double>> weights = <List<double>>[
    weightsFor(frontal, allowFrontal),
    weightsFor(leftSource, allowLeft),
    weightsFor(rightSource, allowRight),
    if (upSource != null) weightsFor(upSource, allowLower),
  ];

  const TextureBaker baker = TextureBaker();
  final List<List<double>> gains = _poseGains(
    baker: baker,
    poses: orderedPoses,
    weights: weights,
    colorMatch: colorMatch,
    neutral: colorMatchNeutral,
  );

  final List<WeightedPose> poses = <WeightedPose>[
    for (int i = 0; i < orderedPoses.length; i++)
      WeightedPose(pose: orderedPoses[i], weight: weights[i], gain: gains[i]),
  ];

  return baker.bakeViewDependent(
    poses: poses,
    uvs: uvs,
    triangles: triangles,
    textureSize: textureSize,
    blend: blend,
  );
}

/// Per-pose colour-match gains. [poses]/[weights] are index-aligned, [poses][0]
/// is frontal. Modes:
///  * `!colorMatch` → all identity (no correction).
///  * `neutral` → normalise EVERY pose (incl. frontal) to a shared target = the
///    per-channel average of the poses' mean face colours (no privileged pose;
///    closest to "all on one default").
///  * else (frontal reference) → frontal identity; each other pose matched to
///    frontal over their overlap.
List<List<double>> _poseGains({
  required TextureBaker baker,
  required List<BakePose> poses,
  required List<List<double>> weights,
  required bool colorMatch,
  required bool neutral,
}) {
  final int n = poses.length;
  const List<double> identity = <double>[1, 1, 1];
  if (!colorMatch) {
    return <List<double>>[for (int i = 0; i < n; i++) identity];
  }

  if (neutral) {
    final List<List<double>?> means = <List<double>?>[
      for (int i = 0; i < n; i++)
        baker.poseMeanColor(pose: poses[i], weight: weights[i]),
    ];
    final List<double> target = <double>[0, 0, 0];
    int valid = 0;
    for (final List<double>? m in means) {
      if (m == null) {
        continue;
      }
      target[0] += m[0];
      target[1] += m[1];
      target[2] += m[2];
      valid++;
    }
    if (valid == 0) {
      return <List<double>>[for (int i = 0; i < n; i++) identity];
    }
    target[0] /= valid;
    target[1] /= valid;
    target[2] /= valid;
    return <List<double>>[
      for (int i = 0; i < n; i++)
        means[i] == null
            ? identity
            : TextureBaker.gainToTarget(means[i]!, target),
    ];
  }

  // Frontal reference: match each other pose to frontal over their overlap.
  final List<double> wFrontal = weights[0];
  return <List<double>>[
    identity, // frontal is the reference
    for (int i = 1; i < n; i++)
      baker.poseGain(
        reference: poses[0],
        pose: poses[i],
        refWeight: wFrontal,
        poseWeight: weights[i],
      ),
  ];
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
  final Matrix4 viewMatrix = Matrix4.fromList(p.viewMatrix);
  final Matrix4 faceTransform = Matrix4.fromList(p.faceTransform);
  return BakePose(
    image: image,
    vertices: verts,
    projection: PoseProjection(
      width: p.width,
      height: p.height,
      viewMatrix: viewMatrix,
      projectionMatrix: Matrix4.fromList(p.projectionMatrix),
      faceTransform: faceTransform,
    ),
    viewMatrix: viewMatrix,
    faceTransform: faceTransform,
  );
}
