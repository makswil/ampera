import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart';

import '../../domain/constants/face_regions.g.dart';
import '../../domain/constants/face_vertex_indices.dart';
import '../../domain/v3/texture_projection.dart';
import '../../domain/v3/vertex_motion.dart';
import '../../domain/v3/vertex_normals.dart';
import '../../domain/v3/view_weights.dart';
import '../session_path.dart';
import 'aperture_pin.dart';
import 'facing_debug_atlas.dart';
import 'motion_debug_atlas.dart';
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

/// Bakes each expression frame. One photo per vertex — no RGB mix of smile
/// and neutral. Clip JPEG where it sees the surface head-on (`n·v` ≥ 0.42)
/// or the mesh moved. L/R / chin-up only where the clip is grazing/blind,
/// the vertex stayed still, and that still saw the point. Does not change
/// 4-pose bake.
final class ExpressionSequenceBaker {
  const ExpressionSequenceBaker();

  Future<ExpressionSequenceBakeResult> bake({
    required String manifestPath,
    int textureSize = 1024,
    /// Match multipose: author eye + mouth cap tris so ARKit apertures aren't holes.
    bool fillHoles = true,
    /// Match Side→Clip RGB over still-region overlap (lighting seams).
    bool colorMatch = true,
    /// Paint source colours instead of photos (clip JPEG = green).
    bool debugSourceColors = false,
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

    final List<ExpressionSequenceBakedFrame> baked =
        <ExpressionSequenceBakedFrame>[];
    const TextureBaker baker = TextureBaker();

    final BakePose? leftCheek = await _loadSupport(exprDir, stem: 'right40');
    final BakePose? rightCheek = await _loadSupport(exprDir, stem: 'left40');
    final BakePose? chinUp = await _loadSupport(exprDir, stem: 'up');

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

    final List<Vector3>? rest = meanVertices(<List<Vector3>>[
      if (leftCheek != null) leftCheek.vertices,
      if (rightCheek != null) rightCheek.vertices,
    ]);
    final List<double> allowSupport;
    if (keep.isNotEmpty) {
      final List<Vector3> restVerts = rest ?? keep.first.vertices;
      final List<double> travel = maxVertexTravel(
        rest: restVerts,
        clips: <List<Vector3>>[
          for (final _LoadedExprFrame f in keep) f.vertices,
        ],
      );
      allowSupport = <double>[
        for (final double d in travel) motionAllowSupport(d),
      ];
    } else {
      allowSupport = const <double>[];
    }

    List<double>? maxFrontalNv;
    for (final _LoadedExprFrame frame in keep) {
      // Normals from expression mesh (open mouth) — not neutral support.
      final List<Vector3> normals =
          computeVertexNormals(frame.vertices, triangles);

      final List<double> nv = viewFacingCosine(
        faceLocalVerts: frame.vertices,
        localNormals: normals,
        viewMatrix: frame.pose.viewMatrix,
        faceTransform: frame.pose.faceTransform,
      );
      if (maxFrontalNv == null) {
        maxFrontalNv = nv;
      } else {
        final int n = nv.length < maxFrontalNv.length
            ? nv.length
            : maxFrontalNv.length;
        for (int i = 0; i < n; i++) {
          if (nv[i] > maxFrontalNv[i]) {
            maxFrontalNv[i] = nv[i];
          }
        }
      }

      final img.Image atlas = _bakeFrame(
        baker: baker,
        frontal: frame.pose,
        leftCheek: leftCheek,
        rightCheek: rightCheek,
        chinUp: chinUp,
        normals: normals,
        allowSupport: allowSupport,
        uvs: uvs,
        triangles: meshTriangles,
        textureSize: textureSize,
        colorMatch: colorMatch &&
            (leftCheek != null || rightCheek != null || chinUp != null),
        debugSourceColors: debugSourceColors,
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
      // Binary xyz floats for smooth viewer morph (avoids ModelIO per frame).
      final Float32List vertsFlat = Float32List(frame.vertices.length * 3);
      for (int i = 0; i < frame.vertices.length; i++) {
        final Vector3 v = frame.vertices[i];
        vertsFlat[i * 3] = v.x;
        vertsFlat[i * 3 + 1] = v.y;
        vertsFlat[i * 3 + 2] = v.z;
      }
      await File('${outDir.path}/$stem.verts').writeAsBytes(
        vertsFlat.buffer.asUint8List(
          vertsFlat.offsetInBytes,
          vertsFlat.lengthInBytes,
        ),
        flush: true,
      );

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
      'debugSourceColors': debugSourceColors,
      'debugLegend': <String, Object?>{
        'frontal': 'green',
        'leftCheek': 'red',
        'rightCheek': 'blue',
        'chinUp': 'yellow',
      },
      'mixSupportStills':
          leftCheek != null || rightCheek != null || chinUp != null,
      'debugNv': <String, String>{
        'png': 'debug_nv.png',
        'bestPng': 'debug_nv_best.png',
        'json': 'debug_nv.json',
      },
      'debugMotion': <String, String>{
        'png': 'debug_motion.png',
        'json': 'debug_motion.json',
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

    if (maxFrontalNv != null && maxFrontalNv.isNotEmpty) {
      await _writeFacingDebug(
        baker: baker,
        outDir: outDir,
        uvs: uvs,
        triangles: triangles,
        textureSize: textureSize,
        frontalNv: maxFrontalNv,
        frames: keep,
        leftCheek: leftCheek,
        rightCheek: rightCheek,
        chinUp: chinUp,
      );
    }

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

  /// One photo per vertex. Clip if `n·v` is good or the mesh moved; else the
  /// support still that sees the point. Eyes + mouth aperture stay clip.
  static img.Image _bakeFrame({
    required TextureBaker baker,
    required BakePose frontal,
    required BakePose? leftCheek,
    required BakePose? rightCheek,
    required BakePose? chinUp,
    required List<Vector3> normals,
    required List<double> allowSupport,
    required List<double> uvs,
    required List<int> triangles,
    required int textureSize,
    required bool colorMatch,
    required bool debugSourceColors,
  }) {
    if (leftCheek == null && rightCheek == null && chinUp == null) {
      final List<double> ones = List<double>.filled(frontal.vertices.length, 1);
      return baker.bakeViewDependent(
        poses: <WeightedPose>[
          WeightedPose(
            pose: frontal,
            weight: ones,
            debugRgb: debugSourceColors ? TextureBaker.debugFrontalRgb : null,
          ),
        ],
        uvs: uvs,
        triangles: triangles,
        textureSize: textureSize,
        blend: true,
        screenSpaceFrontalVertices: FaceHoleGeometry.eyeVertexIndices,
        debugTint: debugSourceColors ? 0.78 : 0,
      );
    }

    final FaceGuardFrame frame = computeGuardFrame(
      verts: frontal.vertices,
      symmetryAxis: FaceSymmetryAxis.ordered,
      horizontalAxis: FaceHorizontalAxis.ordered,
    );
    final List<bool> allowAll =
        List<bool>.filled(frontal.vertices.length, true);
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

    List<double> gatedNv(BakePose pose, List<bool> allowed) {
      final List<double> nv = viewFacingCosine(
        faceLocalVerts: pose.vertices,
        localNormals: normals,
        viewMatrix: pose.viewMatrix,
        faceTransform: pose.faceTransform,
      );
      for (int i = 0; i < nv.length; i++) {
        if (i < allowed.length && !allowed[i]) {
          nv[i] = 0;
        } else if (nv[i] < 0) {
          nv[i] = 0;
        }
      }
      return nv;
    }

    final List<double> clipNv = gatedNv(frontal, allowAll);
    final List<double>? leftNv =
        leftCheek == null ? null : gatedNv(leftCheek, allowLeft);
    final List<double>? rightNv =
        rightCheek == null ? null : gatedNv(rightCheek, allowRight);
    List<double>? chinNv =
        chinUp == null ? null : gatedNv(chinUp, allowLower);
    if (chinNv != null) {
      chinNv = expressionChinUpMouthFalloff(
        weights: chinNv,
        verts: frontal.vertices,
      );
    }

    final int n = clipNv.length;
    final List<double> wFrontal = List<double>.filled(n, 0);
    final List<double>? wLeft =
        leftNv == null ? null : List<double>.filled(leftNv.length, 0);
    final List<double>? wRight =
        rightNv == null ? null : List<double>.filled(rightNv.length, 0);
    final List<double>? wChin =
        chinNv == null ? null : List<double>.filled(chinNv.length, 0);

    final List<BakePose> ordered = <BakePose>[
      frontal,
      ?leftCheek,
      ?rightCheek,
      ?chinUp,
    ];
    // Gain from geometric overlap (both cameras see the point), then exclusive
    // pick — otherwise poseGain has no overlap samples.
    final List<List<double>> gains = _poseGains(
      baker: baker,
      poses: ordered,
      weights: <List<double>>[
        clipNv,
        ?leftNv,
        ?rightNv,
        ?chinNv,
      ],
      colorMatch: colorMatch,
      luminanceOnly: true,
    );

    assignExpressionExclusiveWeights(
      wFrontal: wFrontal,
      wLeft: wLeft,
      wRight: wRight,
      wChin: wChin,
      clipNv: clipNv,
      leftNv: leftNv,
      rightNv: rightNv,
      chinNv: chinNv,
      allowSupport: allowSupport,
    );

    final List<List<double>> weights = <List<double>>[
      wFrontal,
      ?wLeft,
      ?wRight,
      ?wChin,
    ];

    final Set<int> periocular = expandVertexRings(
      seeds: FaceHoleGeometry.eyeVertexIndices,
      triangles: triangles,
      rings: 2,
    );
    pinVerticesToFrontalPose(
      weights: weights,
      frontalVerts: frontal.vertices,
      vertices: <int>[
        ...periocular,
        ...FaceHoleGeometry.mouthVertexIndices,
      ],
    );

    return baker.bakeViewDependent(
      poses: <WeightedPose>[
        for (int i = 0; i < ordered.length; i++)
          WeightedPose(
            pose: ordered[i],
            weight: weights[i],
            gain: gains[i],
            debugRgb: debugSourceColors ? TextureBaker.debugRgbForIndex(i) : null,
          ),
      ],
      uvs: uvs,
      triangles: triangles,
      textureSize: textureSize,
      blend: true,
      screenSpaceFrontalVertices: FaceHoleGeometry.eyeVertexIndices,
      frontalOnlyVertices: periocular,
      debugTint: debugSourceColors ? 0.78 : 0,
    );
  }

  static List<List<double>> _poseGains({
    required TextureBaker baker,
    required List<BakePose> poses,
    required List<List<double>> weights,
    required bool colorMatch,
    bool luminanceOnly = false,
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
          luminanceOnly: luminanceOnly,
        ),
    ];
  }

  /// Coverage debug PNG + JSON. Does not change clip albedo.
  static Future<void> _writeFacingDebug({
    required TextureBaker baker,
    required Directory outDir,
    required List<double> uvs,
    required List<int> triangles,
    required int textureSize,
    required List<double> frontalNv,
    required List<_LoadedExprFrame> frames,
    BakePose? leftCheek,
    BakePose? rightCheek,
    BakePose? chinUp,
  }) async {
    final BakePose? left = leftCheek;
    final BakePose? right = rightCheek;
    final BakePose? chin = chinUp;

    List<double>? nvFor(BakePose? p) {
      if (p == null || p.vertices.length != frontalNv.length) {
        return null;
      }
      final List<Vector3> normals =
          computeVertexNormals(p.vertices, triangles);
      return viewFacingCosine(
        faceLocalVerts: p.vertices,
        localNormals: normals,
        viewMatrix: p.viewMatrix,
        faceTransform: p.faceTransform,
      );
    }

    final List<double>? leftNv = nvFor(left);
    final List<double>? rightNv = nvFor(right);
    final List<double>? chinNv = nvFor(chin);

    final img.Image montage = FacingDebugAtlas.buildMontage(
      baker: baker,
      uvs: uvs,
      triangles: triangles,
      textureSize: textureSize,
      frontalNv: frontalNv,
      leftNv: leftNv,
      rightNv: rightNv,
      chinNv: chinNv,
    );
    await File('${outDir.path}/debug_nv.png').writeAsBytes(
      img.encodePng(montage),
      flush: true,
    );
    final img.Image best = FacingDebugAtlas.buildBestView(
      baker: baker,
      uvs: uvs,
      triangles: triangles,
      textureSize: textureSize,
      frontalNv: frontalNv,
      leftNv: leftNv,
      rightNv: rightNv,
      chinNv: chinNv,
    );
    await File('${outDir.path}/debug_nv_best.png').writeAsBytes(
      img.encodePng(best),
      flush: true,
    );
    await File('${outDir.path}/debug_nv.json').writeAsString(
      const JsonEncoder.withIndent('  ').convert(
        FacingDebugAtlas.legendJson(
          frontalNv: frontalNv,
          leftNv: leftNv,
          rightNv: rightNv,
          chinNv: chinNv,
          leftLoaded: leftNv != null,
          rightLoaded: rightNv != null,
          chinLoaded: chinNv != null,
        ),
      ),
      flush: true,
    );

    final List<List<Vector3>> restSources = <List<Vector3>>[
      if (left != null) left.vertices,
      if (right != null) right.vertices,
    ];
    final List<Vector3>? rest = meanVertices(restSources) ??
        (frames.isNotEmpty ? frames.first.vertices : null);
    if (rest != null && frames.isNotEmpty) {
      final List<double> travel = maxVertexTravel(
        rest: rest,
        clips: <List<Vector3>>[
          for (final _LoadedExprFrame f in frames) f.vertices,
        ],
      );
      final List<FacingFillHint> bestView = <FacingFillHint>[
        for (int i = 0; i < frontalNv.length; i++)
          facingBestView(
            frontal: frontalNv[i],
            left: (leftNv != null && i < leftNv.length) ? leftNv[i] : 0,
            right: (rightNv != null && i < rightNv.length) ? rightNv[i] : 0,
            chinUp: (chinNv != null && i < chinNv.length) ? chinNv[i] : 0,
          ),
      ];
      final img.Image motion = MotionDebugAtlas.buildMontage(
        baker: baker,
        uvs: uvs,
        triangles: triangles,
        textureSize: textureSize,
        displacementM: travel,
        bestView: bestView,
      );
      await File('${outDir.path}/debug_motion.png').writeAsBytes(
        img.encodePng(motion),
        flush: true,
      );
      final String restSource = restSources.isEmpty
          ? 'first clip frame (no L/R support stills)'
          : restSources.length == 2
              ? 'mean of L/R support stills (chin-up excluded)'
              : 'single L/R support still (chin-up excluded)';
      await File('${outDir.path}/debug_motion.json').writeAsString(
        const JsonEncoder.withIndent('  ').convert(
          MotionDebugAtlas.legendJson(
            displacementM: travel,
            bestView: bestView,
            restSource: restSource,
          ),
        ),
        flush: true,
      );
    }
  }

  /// Neutral support still (JPEG + verts + matrices) for motion-gated mix.
  static Future<BakePose?> _loadSupport(
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
    return BakePose(
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

/// Exclusive 0/1 source pick for the expression bake. Clip keeps the vertex
/// when its `n·v` is good, or when no support is strictly better. Otherwise
/// the motion-allowed support with the highest `n·v` wins. No RGB blend.
/// Writes into the weight lists (same length as [clipNv]).
void assignExpressionExclusiveWeights({
  required List<double> wFrontal,
  List<double>? wLeft,
  List<double>? wRight,
  List<double>? wChin,
  required List<double> clipNv,
  List<double>? leftNv,
  List<double>? rightNv,
  List<double>? chinNv,
  required List<double> allowSupport,
  double goodMin = kFacingGoodMin,
}) {
  final int n = clipNv.length;
  void zero(List<double> w) {
    for (int i = 0; i < w.length; i++) {
      w[i] = 0;
    }
  }

  zero(wFrontal);
  if (wLeft != null) {
    zero(wLeft);
  }
  if (wRight != null) {
    zero(wRight);
  }
  if (wChin != null) {
    zero(wChin);
  }

  double nvAt(List<double>? src, int i) =>
      src != null && i < src.length ? src[i] : 0;

  for (int i = 0; i < n; i++) {
    final double clip = clipNv[i];
    if (clip >= goodMin) {
      if (i < wFrontal.length) {
        wFrontal[i] = 1;
      }
      continue;
    }
    final double allow = i < allowSupport.length ? allowSupport[i] : 0;
    final FacingFillHint hint = allow > 0
        ? facingFillHint(
            frontal: clip,
            left: nvAt(leftNv, i),
            right: nvAt(rightNv, i),
            chinUp: nvAt(chinNv, i),
          )
        : FacingFillHint.none;
    switch (hint) {
      case FacingFillHint.left:
        if (wLeft != null && i < wLeft.length) {
          wLeft[i] = 1;
        } else if (i < wFrontal.length) {
          wFrontal[i] = 1;
        }
      case FacingFillHint.right:
        if (wRight != null && i < wRight.length) {
          wRight[i] = 1;
        } else if (i < wFrontal.length) {
          wFrontal[i] = 1;
        }
      case FacingFillHint.chinUp:
        if (wChin != null && i < wChin.length) {
          wChin[i] = 1;
        } else if (i < wFrontal.length) {
          wFrontal[i] = 1;
        }
      case FacingFillHint.clip:
      case FacingFillHint.none:
        if (i < wFrontal.length) {
          wFrontal[i] = 1;
        }
    }
  }
}

/// Expression clip: L/R paint outer face (`sideWeight`) and lateral clip holes
/// (nose wings). Midline holes (under-chin / nostrils) stay for chin-up —
/// gated by |x| / halfSpan, not only the frozen sideWeight table.
List<double> expressionSideSupportWeights({
  required List<double> side,
  required List<double> frontal,
  required List<Vector3> verts,
  required FaceGuardFrame frame,
  double holeEps = 0.02,
  double coverageKill = 0.12,
  double minSideForHole = 0.05,
  /// Min lateral fraction of face half-width to treat a clip hole as a
  /// nose-wing / cheek hole (not under-chin midline).
  double minLateralForHole = 0.10,
}) {
  const List<double> sw = FaceRegions.sideWeight;
  final int n = side.length;
  final double half = frame.halfSpan > 1e-6 ? frame.halfSpan : 1.0;
  final List<double> gated = List<double>.filled(n, 0);
  for (int i = 0; i < n; i++) {
    final double s = side[i];
    if (s <= 0) {
      continue;
    }
    final double f = i < frontal.length ? frontal[i] : 0;
    final double table = i < sw.length ? sw[i] : 0;
    if (f >= holeEps) {
      gated[i] = s * table;
      continue;
    }
    // Clip hole: outer table OR far enough from midline (alar / cheek).
    final double lateral = i < verts.length
        ? (verts[i].x - frame.midlineX).abs() / half
        : 0;
    final bool lateralHole = lateral >= minLateralForHole;
    final bool tableHole = table >= minSideForHole;
    gated[i] = (tableHole || lateralHole) ? s : 0;
  }
  return expressionChinUpGapWeights(
    candidate: gated,
    coveredBy: <List<double>>[frontal],
    coverageKill: coverageKill,
  );
}

/// Chin-up: lower face, midband only (`1 - sideWeight`), gap-fill vs clip + L/R.
/// Mouth rim faded so neutral lips don't stamp onto a smile.
List<double> expressionChinUpSupportWeights({
  required List<double> chinUp,
  required List<double> frontal,
  List<double>? left,
  List<double>? right,
  required List<Vector3> verts,
  double coverageKill = 0.08,
}) {
  final List<double> mid = expressionScaleByCenterWeight(chinUp);
  final List<double> gap = expressionChinUpGapWeights(
    candidate: mid,
    coveredBy: <List<double>>[
      frontal,
      ?left,
      ?right,
    ],
    coverageKill: coverageKill,
  );
  return expressionChinUpMouthFalloff(weights: gap, verts: verts);
}

/// Scale by `(1 - sideWeight)` — keep midface, kill outer L/R bands.
List<double> expressionScaleByCenterWeight(List<double> weights) {
  const List<double> sw = FaceRegions.sideWeight;
  final int n = weights.length;
  return <double>[
    for (int i = 0; i < n; i++)
      weights[i] * (1.0 - (i < sw.length ? sw[i] : 0)),
  ];
}

/// Expression clip: scale pose weights by [FaceRegions.sideWeight] (0 = midface,
/// never take L/R; 1 = outer cheek / temple).
List<double> expressionScaleBySideWeight(List<double> weights) {
  const List<double> sw = FaceRegions.sideWeight;
  final int n = weights.length;
  return <double>[
    for (int i = 0; i < n; i++)
      weights[i] * (i < sw.length ? sw[i] : 0),
  ];
}

/// Smile-clip helper (tests / unused by bake): keep [candidate] only where
/// other poses barely cover the vertex. Soft-ramps to 0 as coverage approaches
/// [coverageKill]. Does **not** change 4-pose bake.
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
    this.debugSourceColors = false,
    this.jpegOverrides,
  });

  final String manifestPath;
  final int textureSize;
  final bool fillHoles;
  final bool colorMatch;
  final bool debugSourceColors;
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
      debugSourceColors: request.debugSourceColors,
      jpegOverrides: request.jpegOverrides,
    ),
  );
}
