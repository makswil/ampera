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
//   --wb-neutral     with --view-dependent: match all poses to their shared
//                    average colour instead of to frontal.
//   --ml-wb          run the ml-wb PyTorch white-balance model over every pose
//                    still BEFORE baking (needs the Python venv, see
//                    tool/ml_wb_correct.py). Normalises all poses to one white
//                    point → removes colour/exposure seams. The deterministic
//                    Dart colour-match (poseGain) still runs on top as before.
//   --ml-wb-reference=frontal  correct toward the frontal still's white balance
//                    instead of neutral daylight (default: neutral ~5600 K).
//   --ml-wb-python=<path>      Python interpreter to use (default: the
//                    tool/.venv-mlwb venv if present, else `python3`).

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
  bool colorNeutral = false;
  bool mlWb = false;
  String? mlWbReference; // 'frontal' or a file path; null = neutral target.
  String? mlWbPython;
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
    } else if (arg == '--wb-neutral') {
      colorNeutral = true;
    } else if (arg == '--ml-wb') {
      mlWb = true;
    } else if (arg.startsWith('--ml-wb-reference=')) {
      mlWb = true;
      mlWbReference = arg.substring('--ml-wb-reference='.length);
    } else if (arg.startsWith('--ml-wb-python=')) {
      mlWbPython = arg.substring('--ml-wb-python='.length);
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
    if (mlWb) 'mlwb',
    '${size}px',
  ].join('_');
  if (positional.isEmpty) {
    stderr.writeln(
      'Usage: dart run tool/bake_texture.dart <session_dir> '
      '[--size=2048] [--flip] [--no-holes] [--no-normals] '
      '[--view-dependent] [--best] [--ml-wb] [--ml-wb-reference=frontal] '
      '[--out=model]',
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

  // Optional: run every pose still through the ml-wb PyTorch white-balance model
  // BEFORE baking, so all poses share one white point (removes colour seams). The
  // ml-wb/ folder is imported read-only by tool/ml_wb_correct.py. Returns a map
  // imageFile → corrected PNG path; empty (originals) if disabled or on failure.
  final Map<String, String> corrected = mlWb
      ? _runMlWb(
          dir: dir,
          poses: poses,
          reference: mlWbReference,
          python: mlWbPython,
        )
      : const <String, String>{};

  final _Ply frontalPly = _loadPly(dir, poses['frontal']);
  BakePose frontal = _loadPose(dir, poses['frontal'], frontalPly, corrected);
  BakePose left40 = _loadPose(dir, poses['left40'], null, corrected);
  BakePose right40 = _loadPose(dir, poses['right40'], null, corrected);
  // Chin-up is optional (older sessions lack it); only used view-dependent.
  BakePose? up =
      poses['up'] == null ? null : _loadPose(dir, poses['up'], null, corrected);

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
          colorNeutral: colorNeutral,
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

/// Runs the ml-wb PyTorch white-balance model (via tool/ml_wb_correct.py) over
/// every pose still, writing corrected PNGs into `<dir>/.mlwb_cache/`. Returns a
/// map `imageFile → corrected PNG path` so [_loadPose] can pick them up. On any
/// failure it warns and returns an empty map, so the bake falls back to the
/// original stills (and the deterministic Dart colour-match still applies).
///
/// The ml-wb/ folder is imported read-only by the wrapper — never modified.
Map<String, String> _runMlWb({
  required Directory dir,
  required Map<String, Map<String, dynamic>> poses,
  String? reference,
  String? python,
}) {
  final String scriptDir = File.fromUri(Platform.script).parent.path;
  final String script = '$scriptDir/ml_wb_correct.py';
  if (!File(script).existsSync()) {
    stderr.writeln('[ml-wb] wrapper not found at $script — skipping (originals).');
    return const <String, String>{};
  }

  // Default to the bundled venv if present, else the system python3.
  String interpreter = python ?? '$scriptDir/.venv-mlwb/bin/python';
  if (python == null && !File(interpreter).existsSync()) {
    interpreter = 'python3';
  }

  // Pose still → its input path; keep the imageFile so we can key the result.
  final Map<String, String> imageFileByInput = <String, String>{};
  final List<String> inputs = <String>[];
  for (final Map<String, dynamic> pose in poses.values) {
    final Object? imageFile = pose['imageFile'];
    if (imageFile is! String) {
      continue;
    }
    final String inputPath = '${dir.path}/$imageFile';
    if (!File(inputPath).existsSync()) {
      continue;
    }
    imageFileByInput[inputPath] = imageFile;
    inputs.add(inputPath);
  }
  if (inputs.isEmpty) {
    return const <String, String>{};
  }

  final String outDir = '${dir.path}/.mlwb_cache';
  final List<String> refArgs = <String>[];
  if (reference != null && reference.isNotEmpty) {
    // 'frontal' → use the frontal still as the white-balance reference.
    final String refPath = reference == 'frontal'
        ? '${dir.path}/${poses['frontal']?['imageFile']}'
        : reference;
    refArgs.addAll(<String>['--reference', refPath]);
  }

  stderr.writeln('[ml-wb] correcting ${inputs.length} still(s) via $interpreter …');
  final ProcessResult result;
  try {
    result = Process.runSync(
      interpreter,
      <String>[script, '--out-dir', outDir, ...refArgs, ...inputs],
    );
  } on ProcessException catch (e) {
    stderr.writeln('[ml-wb] could not start "$interpreter": ${e.message}\n'
        '        Create the venv (see tool/ml_wb_correct.py) or pass '
        '--ml-wb-python=<path>. Falling back to original stills.');
    return const <String, String>{};
  }

  if (result.exitCode != 0) {
    stderr.writeln('[ml-wb] correction failed (exit ${result.exitCode}):\n'
        '${result.stderr}\nFalling back to original stills.');
    return const <String, String>{};
  }

  final Map<String, String> byImageFile = <String, String>{};
  try {
    final Object? decoded = jsonDecode((result.stdout as String).trim());
    if (decoded is Map) {
      decoded.forEach((Object? inputPath, Object? outputPath) {
        final String? imageFile = imageFileByInput[inputPath];
        if (imageFile != null && outputPath is String) {
          byImageFile[imageFile] = outputPath;
        }
      });
    }
  } catch (e) {
    stderr.writeln('[ml-wb] could not parse wrapper output: $e — using originals.');
    return const <String, String>{};
  }

  stderr.writeln('[ml-wb] applied to ${byImageFile.length} pose(s).');
  return byImageFile;
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
  required bool colorNeutral,
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

  final List<BakePose> orderedPoses = <BakePose>[
    frontal,
    leftSource,
    rightSource,
    ?up,
  ];
  final List<List<double>> weights = <List<double>>[
    weightsFor(frontal, PoseGuard.frontalCenter),
    weightsFor(leftSource, PoseGuard.leftHalf),
    weightsFor(rightSource, PoseGuard.rightHalf),
    if (up != null) weightsFor(up, PoseGuard.lowerHalf),
  ];

  const TextureBaker baker = TextureBaker();
  final List<List<double>> gains = _poseGains(
    baker: baker,
    poses: orderedPoses,
    weights: weights,
    colorMatch: colorMatch,
    neutral: colorNeutral,
  );

  final List<WeightedPose> weighted = <WeightedPose>[
    for (int i = 0; i < orderedPoses.length; i++)
      WeightedPose(pose: orderedPoses[i], weight: weights[i], gain: gains[i]),
  ];

  return baker.bakeViewDependent(
    poses: weighted,
    uvs: uvs,
    triangles: triangles,
    textureSize: size,
    blend: blend,
  );
}

/// Mirrors `session_baker._poseGains`: per-pose colour-match gains. [poses][0] is
/// frontal. `neutral` → normalise all poses to their shared average; else match
/// each other pose to frontal.
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
  final List<double> wFrontal = weights[0];
  return <List<double>>[
    identity,
    for (int i = 1; i < n; i++)
      baker.poseGain(
        reference: poses[0],
        pose: poses[i],
        refWeight: wFrontal,
        poseWeight: weights[i],
      ),
  ];
}

BakePose _loadPose(
  Directory dir,
  Map<String, dynamic>? pose, [
  _Ply? preloaded,
  Map<String, String> imageOverride = const <String, String>{},
]) {
  if (pose == null) {
    throw StateError('Missing pose in manifest (need frontal/left40/right40).');
  }
  final _Ply ply = preloaded ?? _loadPly(dir, pose);
  final Map<String, dynamic> still = pose['still'] as Map<String, dynamic>? ??
      (throw StateError('Pose ${pose['pose']} has no still projection.'));

  // Prefer the ml-wb-corrected still (PNG) when present; else the original JPEG.
  final String imageFile = pose['imageFile'] as String;
  final String imagePath =
      imageOverride[imageFile] ?? '${dir.path}/$imageFile';
  final img.Image? image =
      img.decodeImage(File(imagePath).readAsBytesSync());
  if (image == null) {
    throw StateError('Could not decode $imagePath.');
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
