import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart';

import '../../domain/constants/face_vertex_indices.dart';
import '../../domain/v3/texture_projection.dart';
import '../../domain/v3/vertex_normals.dart';
import '../../domain/v3/view_weights.dart';
import '../session_path.dart';
import 'aperture_pin.dart';
import 'obj_writer.dart';
import 'texture_baker.dart';

/// One textured mesh frame from an expression sequence bake.
final class ExpressionSequenceBakedFrame {
  const ExpressionSequenceBakedFrame({
    required this.index,
    required this.objPath,
    required this.texturePath,
  });

  final int index;
  final String objPath;
  final String texturePath;
}

/// Result of baking an expression sequence into per-frame OBJ + PNG.
final class ExpressionSequenceBakeResult {
  const ExpressionSequenceBakeResult({
    required this.frames,
    required this.directoryPath,
    required this.primaryObjPath,
    this.repairedNoseOutliers = 0,
  });

  final List<ExpressionSequenceBakedFrame> frames;
  final String directoryPath;

  /// First frame OBJ — opens in the existing single-model viewer path.
  final String primaryObjPath;

  /// Frames whose nose mesh was replaced by a neighbor lerp (ARKit glitch).
  final int repairedNoseOutliers;
}

/// Optional neutral side still used to fill occluded frontal regions.
final class _SupportBakePose {
  const _SupportBakePose({
    required this.pose,
    required this.stem,
  });

  final BakePose pose;
  final String stem;
}

/// Bakes each expression frame; merges static L/R support stills via n·v when
/// present under `expression/support/`.
final class ExpressionSequenceBaker {
  const ExpressionSequenceBaker();

  Future<ExpressionSequenceBakeResult> bake({
    required String manifestPath,
    int textureSize = 1024,
    /// Match multipose: author eye + mouth cap tris so ARKit apertures aren't holes.
    bool fillHoles = true,
    /// Match Side→Expression-Frame RGB over overlap (lighting seams).
    bool colorMatch = true,
    /// Optional corrected JPEG bytes keyed by basename (e.g. `frame_000.jpg`).
    /// When set, overrides the on-disk file for that frame.
    Map<String, Uint8List>? jpegOverrides,
  }) async {
    final File manifestFile = File(manifestPath);
    if (!manifestFile.existsSync()) {
      throw StateError('expression bake: missing manifest at $manifestPath');
    }
    final Object? decoded = jsonDecode(await manifestFile.readAsString());
    if (decoded is! Map<String, dynamic>) {
      throw StateError('expression bake: manifest is not a JSON object');
    }
    final Directory exprDir = manifestFile.parent;
    final List<dynamic> rawFrames =
        decoded['frames'] as List<dynamic>? ?? const <dynamic>[];
    final List<int> triangles = _intList(decoded['triangleIndices']);
    final List<double> uvs = _doubleList(decoded['textureCoordinates']);
    if (rawFrames.isEmpty) {
      throw StateError(
        'expression bake: 0 frames in manifest '
        '(dir=${exprDir.path})',
      );
    }
    if (triangles.isEmpty || uvs.isEmpty) {
      throw StateError(
        'expression bake: missing topology '
        '(tris=${triangles.length}, uvs=${uvs.length})',
      );
    }

    final List<int> meshTriangles = fillHoles
        ? <int>[...triangles, ...FaceHoleGeometry.holeTriangles]
        : triangles;

    final Directory outDir = Directory('${exprDir.path}/baked');
    if (outDir.existsSync()) {
      await outDir.delete(recursive: true);
    }
    await outDir.create(recursive: true);

    // left40 = user turned left → camera sees right cheek → rightHalf source.
    // right40 = user turned right → camera sees left cheek → leftHalf source.
    // Matches SessionTextureBaker (flipSides=false).
    final _SupportBakePose? rightCheek = await _loadSupport(
      exprDir,
      stem: 'left40',
    );
    final _SupportBakePose? leftCheek = await _loadSupport(
      exprDir,
      stem: 'right40',
    );
    final _SupportBakePose? chinUp = await _loadSupport(
      exprDir,
      stem: 'up',
    );

    final List<ExpressionSequenceBakedFrame> baked =
        <ExpressionSequenceBakedFrame>[];
    const TextureBaker baker = TextureBaker();

    // Load frames first so we can repair ARKit nose-collapse outliers (1–3
    // frames where the tip jumps short while isTracked stays true).
    final List<_LoadedExprFrame> loaded = <_LoadedExprFrame>[];
    for (final dynamic raw in rawFrames) {
      if (raw is! Map<String, dynamic>) {
        continue;
      }
      final _LoadedExprFrame? frame = await _loadFrame(
        raw: raw,
        exprDir: exprDir,
        jpegOverrides: jpegOverrides,
        fallbackIndex: loaded.length,
      );
      if (frame != null) {
        loaded.add(frame);
      }
    }
    final ({List<_LoadedExprFrame> frames, int repaired}) repaired =
        _repairNoseOutlierFrames(loaded);
    final List<_LoadedExprFrame> keep = List<_LoadedExprFrame>.from(
      repaired.frames,
    )..sort(
        (_LoadedExprFrame a, _LoadedExprFrame b) => a.index.compareTo(b.index),
      );
    final int noseRepaired = repaired.repaired;

    for (final _LoadedExprFrame frame in keep) {
      // Normals from expression mesh (open mouth) — not neutral support.
      final List<Vector3> normals =
          computeVertexNormals(frame.vertices, triangles);

      final img.Image atlas = _bakeFrame(
        baker: baker,
        frontal: frame.pose,
        leftCheek: leftCheek?.pose,
        rightCheek: rightCheek?.pose,
        chinUp: chinUp?.pose,
        normals: normals,
        uvs: uvs,
        triangles: meshTriangles,
        textureSize: textureSize,
        colorMatch: colorMatch &&
            (leftCheek != null || rightCheek != null || chinUp != null),
      );

      final String stem = 'frame_${frame.index.toString().padLeft(4, '0')}';
      final String pngName = '$stem.png';
      final String objName = '$stem.obj';
      final String mtlName = '$stem.mtl';
      final File pngFile = File('${outDir.path}/$pngName');
      await pngFile.writeAsBytes(img.encodePng(atlas), flush: true);

      final String obj = renderObj(
        vertices: frame.vertices,
        uvs: uvs,
        normals: normals,
        triangles: meshTriangles,
        materialName: 'face',
        mtlName: mtlName,
      );
      final String mtl = renderMtl(
        materialName: 'face',
        pngName: pngName,
      );
      final String objPath = '${outDir.path}/$objName';
      await File(objPath).writeAsString(obj, flush: true);
      await File('${outDir.path}/$mtlName').writeAsString(mtl, flush: true);

      baked.add(
        ExpressionSequenceBakedFrame(
          index: frame.index,
          objPath: objPath,
          texturePath: pngFile.path,
        ),
      );
    }

    if (baked.isEmpty) {
      throw StateError(
        'expression bake: skipped all ${rawFrames.length} frames '
        '(missing jpg/verts/matrices under ${exprDir.path})',
      );
    }

    final Map<String, Object?> bakeManifest = <String, Object?>{
      'frameCount': baked.length,
      'repairedNoseOutliers': noseRepaired,
      'noseScores': <double>[
        for (final _LoadedExprFrame f in loaded) expressionNoseScore(f.vertices),
      ],
      'support': <String, Object?>{
        'left40': rightCheek != null, // user-left → right cheek texture
        'right40': leftCheek != null, // user-right → left cheek texture
        'up': chinUp != null,
      },
      'frames': <Map<String, Object?>>[
        for (final ExpressionSequenceBakedFrame f in baked)
          <String, Object?>{
            'index': f.index,
            'obj': f.objPath.split('/').last,
            'png': f.texturePath.split('/').last,
          },
      ],
    };
    await File('${outDir.path}/bake_manifest.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(bakeManifest),
      flush: true,
    );

    return ExpressionSequenceBakeResult(
      frames: baked,
      directoryPath: outDir.path,
      primaryObjPath: baked.first.objPath,
      repairedNoseOutliers: noseRepaired,
    );
  }

  static Future<_LoadedExprFrame?> _loadFrame({
    required Map<String, dynamic> raw,
    required Directory exprDir,
    required Map<String, Uint8List>? jpegOverrides,
    required int fallbackIndex,
  }) async {
    final int index = (raw['index'] as num?)?.toInt() ?? fallbackIndex;
    final String jpgName = raw['jpg'] as String? ?? '';
    final String vertsName = raw['verts'] as String? ?? '';
    final File? jpgFile = SessionPath.fileUnderRoot(exprDir, jpgName);
    final File? vertsFile = SessionPath.fileUnderRoot(exprDir, vertsName);
    if (vertsFile == null || !vertsFile.existsSync()) {
      return null;
    }

    final Uint8List? override = jpegOverrides?[jpgName];
    final Uint8List jpegBytes;
    if (override != null) {
      jpegBytes = override;
    } else if (jpgFile != null && jpgFile.existsSync()) {
      jpegBytes = await jpgFile.readAsBytes();
    } else {
      return null;
    }
    final img.Image? image = img.decodeJpg(jpegBytes);
    if (image == null) {
      return null;
    }
    final Float32List vertsFlat = Float32List.view(
      (await vertsFile.readAsBytes()).buffer,
    );
    final List<Vector3> vertices = <Vector3>[
      for (int i = 0; i + 2 < vertsFlat.length; i += 3)
        Vector3(vertsFlat[i], vertsFlat[i + 1], vertsFlat[i + 2]),
    ];

    final List<double> viewMatrix = _doubleList(raw['viewMatrix']);
    final List<double> projectionMatrix = _doubleList(raw['projectionMatrix']);
    final List<double> faceTransform = _doubleList(raw['faceTransform']);
    if (viewMatrix.length != 16 ||
        projectionMatrix.length != 16 ||
        faceTransform.length != 16) {
      return null;
    }

    final Matrix4 view = Matrix4.fromList(viewMatrix);
    final Matrix4 face = Matrix4.fromList(faceTransform);
    return _LoadedExprFrame(
      index: index,
      vertices: vertices,
      pose: BakePose(
        image: image,
        vertices: vertices,
        projection: PoseProjection(
          width: (raw['width'] as num?)?.toInt() ?? image.width,
          height: (raw['height'] as num?)?.toInt() ?? image.height,
          viewMatrix: view,
          projectionMatrix: Matrix4.fromList(projectionMatrix),
          faceTransform: face,
        ),
        viewMatrix: view,
        faceTransform: face,
      ),
    );
  }

  /// View-dependent merge: expression frontal + optional static cheeks/chin-up.
  ///
  /// Chin-up is **gap-fill only** (smile-clip policy): after lowerHalf + n·v, any
  /// vertex already covered by frontal/L/R is zeroed. Does not change 4-pose bake.
  static img.Image _bakeFrame({
    required TextureBaker baker,
    required BakePose frontal,
    required BakePose? leftCheek,
    required BakePose? rightCheek,
    required BakePose? chinUp,
    required List<Vector3> normals,
    required List<double> uvs,
    required List<int> triangles,
    required int textureSize,
    required bool colorMatch,
  }) {
    if (leftCheek == null && rightCheek == null && chinUp == null) {
      final List<double> ones = List<double>.filled(frontal.vertices.length, 1);
      return baker.bakeViewDependent(
        poses: <WeightedPose>[
          WeightedPose(pose: frontal, weight: ones),
        ],
        uvs: uvs,
        triangles: triangles,
        textureSize: textureSize,
        blend: true,
      );
    }

    final FaceGuardFrame frame = computeGuardFrame(
      verts: frontal.vertices,
      symmetryAxis: FaceSymmetryAxis.ordered,
      horizontalAxis: FaceHorizontalAxis.ordered,
    );
    final List<bool> allowFrontal = poseAllowMask(
      verts: frontal.vertices,
      frame: frame,
      guard: PoseGuard.frontalCenter,
    );
    final List<bool> allowLeft = poseAllowMask(
      verts: frontal.vertices,
      frame: frame,
      guard: PoseGuard.leftHalf,
    );
    final List<bool> allowRight = poseAllowMask(
      verts: frontal.vertices,
      frame: frame,
      guard: PoseGuard.rightHalf,
    );
    final List<bool> allowLower = poseAllowMask(
      verts: frontal.vertices,
      frame: frame,
      guard: PoseGuard.lowerHalf,
    );

    List<double> weightsFor(
      BakePose pose,
      List<bool> allowed, {
      double minFacing = kDefaultMinFacing,
    }) =>
        viewFacingWeights(
          faceLocalVerts: pose.vertices,
          localNormals: normals,
          viewMatrix: pose.viewMatrix,
          faceTransform: pose.faceTransform,
          allowed: allowed,
          minFacing: minFacing,
        );

    // Frontal: stricter minFacing so grazing / nose-wing-occluded surfaces
    // (alar crease) don't pull stretched frontal pixels through the nose.
    // Sides keep the default — they actually see that recess.
    const double kFrontalMinFacing = 0.38;
    final List<bool> allowAll =
        List<bool>.filled(frontal.vertices.length, true);
    final bool hasSides = leftCheek != null || rightCheek != null;
    final List<double> wFrontal = weightsFor(
      frontal,
      hasSides ? allowFrontal : allowAll,
      minFacing: kFrontalMinFacing,
    );
    final List<double>? wLeft =
        leftCheek == null ? null : weightsFor(leftCheek, allowLeft);
    final List<double>? wRight =
        rightCheek == null ? null : weightsFor(rightCheek, allowRight);

    final List<BakePose> ordered = <BakePose>[
      frontal,
      ?leftCheek,
      ?rightCheek,
    ];
    final List<List<double>> weights = <List<double>>[
      wFrontal,
      ?wLeft,
      ?wRight,
    ];

    if (chinUp != null) {
      final List<double> wChinRaw = weightsFor(chinUp, allowLower);
      final List<double> wChinGap = expressionChinUpGapWeights(
        candidate: wChinRaw,
        coveredBy: <List<double>>[
          wFrontal,
          ?wLeft,
          ?wRight,
        ],
        // Stricter than default 0.08: even light frontal/side coverage kills
        // chin-up (less lip double-exposure; nostrils only where truly blind).
        coverageKill: 0.025,
      );
      // Kill chin-up on/near lips (neutral still ≠ smile). Keep strength toward
      // nostrils — distance falloff, not frontal pin-halo (that washed lip colour).
      final List<double> wChin = expressionChinUpMouthFalloff(
        weights: wChinGap,
        verts: frontal.vertices,
      );
      ordered.add(chinUp);
      weights.add(wChin);
    }

    // Neutral support stills ≠ smiling/hi-res eye+mouth shape. Blending them
    // onto deformable apertures ghosts lashes/iris onto lids. Pin aperture +
    // a small periocular halo to the expression/hi-res frontal only.
    // No mouth halo: expanding onto lip flesh sampled wrong skin from the
    // open-mouth photo at the corners ("foreign mouth").
    pinVerticesToFrontalPose(
      weights: weights,
      frontalVerts: frontal.vertices,
      vertices: <int>[
        ...FaceHoleGeometry.eyeVertexIndices,
        ...FaceHoleGeometry.mouthVertexIndices,
      ],
      haloSeeds: FaceHoleGeometry.eyeVertexIndices,
    );

    final List<List<double>> gains = _poseGains(
      baker: baker,
      poses: ordered,
      weights: weights,
      colorMatch: colorMatch,
    );

    return baker.bakeViewDependent(
      poses: <WeightedPose>[
        for (int i = 0; i < ordered.length; i++)
          WeightedPose(pose: ordered[i], weight: weights[i], gain: gains[i]),
      ],
      uvs: uvs,
      triangles: triangles,
      textureSize: textureSize,
      blend: true,
    );
  }

  static List<List<double>> _poseGains({
    required TextureBaker baker,
    required List<BakePose> poses,
    required List<List<double>> weights,
    required bool colorMatch,
  }) {
    const List<double> identity = <double>[1, 1, 1];
    if (!colorMatch || poses.length < 2) {
      return <List<double>>[for (int i = 0; i < poses.length; i++) identity];
    }
    final List<double> wFrontal = weights[0];
    return <List<double>>[
      identity,
      for (int i = 1; i < poses.length; i++)
        baker.poseGain(
          reference: poses[0],
          pose: poses[i],
          refWeight: wFrontal,
          poseWeight: weights[i],
        ),
    ];
  }

  static Future<_SupportBakePose?> _loadSupport(
    Directory exprDir, {
    required String stem,
  }) async {
    final Directory support = Directory('${exprDir.path}/support');
    final File metaFile = File('${support.path}/$stem.json');
    final File jpgFile = File('${support.path}/$stem.jpg');
    final File vertsFile = File('${support.path}/$stem.verts');
    if (!metaFile.existsSync() ||
        !jpgFile.existsSync() ||
        !vertsFile.existsSync()) {
      return null;
    }
    final Object? decoded = jsonDecode(await metaFile.readAsString());
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final img.Image? image = img.decodeJpg(await jpgFile.readAsBytes());
    if (image == null) {
      return null;
    }
    final Float32List vertsFlat = Float32List.view(
      (await vertsFile.readAsBytes()).buffer,
    );
    final List<Vector3> vertices = <Vector3>[
      for (int i = 0; i + 2 < vertsFlat.length; i += 3)
        Vector3(vertsFlat[i], vertsFlat[i + 1], vertsFlat[i + 2]),
    ];
    final List<double> viewMatrix = _doubleList(decoded['viewMatrix']);
    final List<double> projectionMatrix = _doubleList(decoded['projectionMatrix']);
    final List<double> faceTransform = _doubleList(decoded['faceTransform']);
    if (viewMatrix.length != 16 ||
        projectionMatrix.length != 16 ||
        faceTransform.length != 16) {
      return null;
    }
    final Matrix4 view = Matrix4.fromList(viewMatrix);
    final Matrix4 face = Matrix4.fromList(faceTransform);
    return _SupportBakePose(
      stem: stem,
      pose: BakePose(
        image: image,
        vertices: vertices,
        projection: PoseProjection(
          width: (decoded['width'] as num?)?.toInt() ?? image.width,
          height: (decoded['height'] as num?)?.toInt() ?? image.height,
          viewMatrix: view,
          projectionMatrix: Matrix4.fromList(projectionMatrix),
          faceTransform: face,
        ),
        viewMatrix: view,
        faceTransform: face,
      ),
    );
  }

  static List<int> _intList(Object? raw) {
    if (raw is! List) {
      return const <int>[];
    }
    return <int>[
      for (final Object? e in raw)
        if (e is num) e.toInt(),
    ];
  }

  static List<double> _doubleList(Object? raw) {
    if (raw is! List) {
      return const <double>[];
    }
    return <double>[
      for (final Object? e in raw)
        if (e is num) e.toDouble(),
    ];
  }
}

/// Smile-clip only: keep [candidate] (chin-up n·v) only where other poses barely
/// cover the vertex. Soft-ramps to 0 as coverage approaches [coverageKill].
///
/// Does **not** change 4-pose bake — used only by [ExpressionSequenceBaker].
List<double> expressionChinUpGapWeights({
  required List<double> candidate,
  required List<List<double>> coveredBy,
  double coverageKill = 0.08,
}) {
  final int n = candidate.length;
  final List<double> out = List<double>.filled(n, 0);
  if (coverageKill <= 0) {
    return out;
  }
  for (int i = 0; i < n; i++) {
    final double c = candidate[i];
    if (c <= 0) {
      continue;
    }
    double maxOther = 0;
    for (final List<double> w in coveredBy) {
      if (i < w.length && w[i] > maxOther) {
        maxOther = w[i];
      }
    }
    if (maxOther >= coverageKill) {
      continue;
    }
    final double gate = (1.0 - maxOther / coverageKill).clamp(0.0, 1.0);
    out[i] = c * gate;
  }
  return out;
}

/// Smile-clip only: fade chin-up to 0 near the mouth rim, full by [outerRadius].
///
/// Lip flesh stays on the expression frame; under-nose / nostrils (farther from
/// the rim) keep chin-up gap-fill. Does not change 4-pose bake.
List<double> expressionChinUpMouthFalloff({
  required List<double> weights,
  required List<Vector3> verts,
  double innerRadius = 0.014,
  double outerRadius = 0.030,
}) {
  final int n = weights.length;
  final List<double> out = List<double>.filled(n, 0);
  if (outerRadius <= innerRadius) {
    return out;
  }
  final List<Vector3> rim = <Vector3>[
    for (final int i in FaceHoleGeometry.mouthOutline)
      if (i >= 0 && i < verts.length) verts[i],
  ];
  if (rim.isEmpty) {
    return List<double>.from(weights);
  }
  final double span = outerRadius - innerRadius;
  for (int i = 0; i < n; i++) {
    final double w = i < weights.length ? weights[i] : 0;
    if (w <= 0 || i >= verts.length) {
      continue;
    }
    final Vector3 p = verts[i];
    double minD2 = double.infinity;
    for (final Vector3 r in rim) {
      final double d2 = (p - r).length2;
      if (d2 < minD2) {
        minD2 = d2;
      }
    }
    final double d = math.sqrt(minD2);
    if (d <= innerRadius) {
      continue; // fully killed
    }
    if (d >= outerRadius) {
      out[i] = w;
      continue;
    }
    final double t = ((d - innerRadius) / span).clamp(0.0, 1.0);
    // Smoothstep for a softer seam than a linear ramp.
    final double s = t * t * (3.0 - 2.0 * t);
    out[i] = w * s;
  }
  return out;
}

/// Face-local nose length / face length. Tip≈9, bridge≈19 on [FaceSymmetryAxis].
double expressionNoseScaleRatio(List<Vector3> verts) {
  const int tip = 9;
  const int bridge = 19;
  final int forehead = FaceSymmetryAxis.foreheadVertex;
  final int chin = FaceSymmetryAxis.chinVertex;
  if (verts.length <= chin ||
      verts.length <= tip ||
      verts.length <= bridge ||
      verts.length <= forehead) {
    return 0;
  }
  final double faceLen = (verts[forehead] - verts[chin]).length;
  if (faceLen < 1e-6) {
    return 0;
  }
  return (verts[tip] - verts[bridge]).length / faceLen;
}

/// Tip forward of bridge along local Z, normalized by face length.
double expressionNoseProtrusionRatio(List<Vector3> verts) {
  const int tip = 9;
  const int bridge = 19;
  final int forehead = FaceSymmetryAxis.foreheadVertex;
  final int chin = FaceSymmetryAxis.chinVertex;
  if (verts.length <= chin ||
      verts.length <= tip ||
      verts.length <= bridge ||
      verts.length <= forehead) {
    return 0;
  }
  final double faceLen = (verts[forehead] - verts[chin]).length;
  if (faceLen < 1e-6) {
    return 0;
  }
  // ARKit face-local: +Z out of the face. Collapse → tip retracts toward bridge.
  return (verts[tip].z - verts[bridge].z).abs() / faceLen;
}

/// Combined nose health score (length × protrusion). Collapses when either dies.
double expressionNoseScore(List<Vector3> verts) {
  return expressionNoseScaleRatio(verts) * expressionNoseProtrusionRatio(verts);
}

/// Indices marked as nose-collapse outliers (global + temporal gates).
List<int> expressionNoseOutlierIndices(
  List<double> scores, {
  double minFractionOfMedian = 0.92,
  double temporalFraction = 0.90,
  int temporalRadius = 3,
}) {
  final int n = scores.length;
  if (n < 3) {
    return const <int>[];
  }
  final List<double> sorted = List<double>.from(scores)..sort();
  final double median = sorted[n ~/ 2];
  if (median < 1e-6) {
    return const <int>[];
  }
  final double globalFloor = median * minFractionOfMedian;
  final List<int> bad = <int>[];
  for (int i = 0; i < n; i++) {
    final double s = scores[i];
    if (s < globalFloor) {
      bad.add(i);
      continue;
    }
    // Local median of neighbours (excludes self) catches short spikes even when
    // the absolute drop is milder than the global gate.
    final List<double> local = <double>[
      for (int j = i - temporalRadius; j <= i + temporalRadius; j++)
        if (j >= 0 && j < n && j != i) scores[j],
    ];
    if (local.length < 2) {
      continue;
    }
    local.sort();
    final double localMed = local[local.length ~/ 2];
    if (localMed > 1e-6 && s < localMed * temporalFraction) {
      bad.add(i);
    }
  }
  // Never wipe a sequence — if almost everything flags, treat as noise.
  if (bad.length > n ~/ 2 || n - bad.length < 2) {
    return const <int>[];
  }
  return bad;
}

/// Stable mid-face point (symmetry-axis mean). Not used for mesh repair —
/// lip/chin motion during a smile shifts this and would false-positive.
Vector3 expressionFaceCentroid(List<Vector3> verts) {
  const List<int> axis = FaceSymmetryAxis.ordered;
  double x = 0, y = 0, z = 0;
  int n = 0;
  for (final int i in axis) {
    if (i < 0 || i >= verts.length) {
      continue;
    }
    final Vector3 v = verts[i];
    x += v.x;
    y += v.y;
    z += v.z;
    n++;
  }
  if (n == 0) {
    return Vector3.zero();
  }
  return Vector3(x / n, y / n, z / n);
}

/// Frames whose mid-face centroid jumps vs the sequence median.
///
/// Kept for diagnostics/tests only — **do not** feed into mesh repair during
/// expression clips (open smile moves lips/chin on the symmetry axis).
List<int> expressionCentroidOutlierIndices(
  List<Vector3> centroids, {
  required double faceLen,
  double maxFractionOfFace = 0.045,
}) {
  final int n = centroids.length;
  if (n < 3 || faceLen < 1e-6) {
    return const <int>[];
  }
  final List<double> xs = <double>[for (final Vector3 c in centroids) c.x]
    ..sort();
  final List<double> ys = <double>[for (final Vector3 c in centroids) c.y]
    ..sort();
  final List<double> zs = <double>[for (final Vector3 c in centroids) c.z]
    ..sort();
  final Vector3 med = Vector3(xs[n ~/ 2], ys[n ~/ 2], zs[n ~/ 2]);
  final double globalFloor = faceLen * maxFractionOfFace;
  final List<int> bad = <int>[
    for (int i = 0; i < n; i++)
      if (centroids[i].distanceTo(med) > globalFloor) i,
  ];
  if (bad.length > n ~/ 2 || n - bad.length < 2) {
    return const <int>[];
  }
  return bad;
}

/// Indices to keep (legacy helper used by tests).
List<int> expressionNoseKeepIndices(
  List<double> ratios, {
  double minFractionOfMedian = 0.92,
}) {
  final Set<int> bad = expressionNoseOutlierIndices(
    ratios,
    minFractionOfMedian: minFractionOfMedian,
  ).toSet();
  return <int>[
    for (int i = 0; i < ratios.length; i++)
      if (!bad.contains(i)) i,
  ];
}

/// Rebuilds collapsed-nose frames by lerping verts from neighbouring good frames.
///
/// Only nose-score outliers — never centroid jumps (those fire on real smiles).
({List<_LoadedExprFrame> frames, int repaired}) _repairNoseOutlierFrames(
  List<_LoadedExprFrame> frames, {
  double minFractionOfMedian = 0.92,
}) {
  if (frames.length < 3) {
    return (frames: frames, repaired: 0);
  }
  final List<double> scores = <double>[
    for (final _LoadedExprFrame f in frames) expressionNoseScore(f.vertices),
  ];
  final List<int> badList = expressionNoseOutlierIndices(
    scores,
    minFractionOfMedian: minFractionOfMedian,
  );
  if (badList.isEmpty) {
    return (frames: frames, repaired: 0);
  }
  final Set<int> bad = badList.toSet();
  final List<_LoadedExprFrame> out = List<_LoadedExprFrame>.from(frames);
  for (final int i in badList) {
    int? lo;
    int? hi;
    for (int j = i - 1; j >= 0; j--) {
      if (!bad.contains(j)) {
        lo = j;
        break;
      }
    }
    for (int j = i + 1; j < frames.length; j++) {
      if (!bad.contains(j)) {
        hi = j;
        break;
      }
    }
    final List<Vector3> verts;
    if (lo != null && hi != null) {
      final double t = (i - lo) / (hi - lo);
      verts = _lerpVerts(frames[lo].vertices, frames[hi].vertices, t);
    } else if (lo != null) {
      verts = List<Vector3>.from(frames[lo].vertices);
    } else if (hi != null) {
      verts = List<Vector3>.from(frames[hi].vertices);
    } else {
      continue;
    }
    final _LoadedExprFrame src = frames[i];
    out[i] = _LoadedExprFrame(
      index: src.index,
      vertices: verts,
      pose: BakePose(
        image: src.pose.image,
        vertices: verts,
        projection: src.pose.projection,
        viewMatrix: src.pose.viewMatrix,
        faceTransform: src.pose.faceTransform,
      ),
    );
  }
  return (frames: out, repaired: badList.length);
}

List<Vector3> _lerpVerts(List<Vector3> a, List<Vector3> b, double t) {
  final int n = a.length < b.length ? a.length : b.length;
  final double u = 1.0 - t;
  return <Vector3>[
    for (int i = 0; i < n; i++) a[i] * u + b[i] * t,
  ];
}

final class _LoadedExprFrame {
  const _LoadedExprFrame({
    required this.index,
    required this.vertices,
    required this.pose,
  });

  final int index;
  final List<Vector3> vertices;
  final BakePose pose;
}

/// Arguments for [bakeExpressionSequenceInBackground] (must be isolate-safe).
final class ExpressionSequenceBakeRequest {
  const ExpressionSequenceBakeRequest({
    required this.manifestPath,
    this.textureSize = 1024,
    this.fillHoles = true,
    this.colorMatch = true,
    this.jpegOverrides,
  });

  final String manifestPath;
  final int textureSize;
  final bool fillHoles;
  final bool colorMatch;
  final Map<String, Uint8List>? jpegOverrides;
}

/// Runs [ExpressionSequenceBaker.bake] off the UI isolate so the Generate
/// spinner can keep animating.
Future<ExpressionSequenceBakeResult> bakeExpressionSequenceInBackground(
  ExpressionSequenceBakeRequest request,
) {
  return Isolate.run(
    () => const ExpressionSequenceBaker().bake(
      manifestPath: request.manifestPath,
      textureSize: request.textureSize,
      fillHoles: request.fillHoles,
      colorMatch: request.colorMatch,
      jpegOverrides: request.jpegOverrides,
    ),
  );
}
