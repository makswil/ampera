// Standalone dev tool (run with `dart run`, NOT part of the app).
//
// Reads a neutral **frontal** ARKit face PLY and classifies every vertex into a
// left/center/right region (with blend bands), by its local X position relative
// to the face midline. Emits a generated Dart constant table used by the V3
// merge + the in-app region-colouring tool.
//
// Because the ARKit face mesh has fixed topology (vertex i = same landmark on
// every face), the classification computed once here applies to everyone — the
// per-face width only affects this one-time reference pass.
//
// Usage:
//   dart run tool/generate_face_regions.dart <frontal.ply> \
//       [--center=0.34] [--blend=0.12] [--out=<path>]
//
//   --center  half-width fraction (0..1) that stays pure frontal (center region)
//   --blend   additional fraction on each side used as a frontal<->side blend
//             (everything beyond center+blend is the outer/side region)
//
// Example:
//   dart run tool/generate_face_regions.dart tool/reference/frontal.ply

import 'dart:io';

import 'package:flutter_face_scan/features/face_capture/domain/constants/face_vertex_indices.dart';

const String _defaultOut =
    'lib/features/face_capture/domain/constants/face_regions.g.dart';

void main(List<String> args) {
  final _Args parsed = _parseArgs(args);
  if (parsed.plyPath == null) {
    stderr.writeln(
      'Usage: dart run tool/generate_face_regions.dart <frontal.ply> '
      '[--center=0.34] [--blend=0.12] [--out=path]',
    );
    exit(64);
  }

  final File plyFile = File(parsed.plyPath!);
  if (!plyFile.existsSync()) {
    stderr.writeln('PLY not found: ${parsed.plyPath}');
    exit(66);
  }

  final _Ply ply = _parsePly(plyFile.readAsStringSync());
  final List<_V3> verts = ply.verts;
  if (verts.isEmpty) {
    stderr.writeln('No vertices parsed from ${parsed.plyPath}');
    exit(65);
  }
  stdout.writeln('Parsed ${verts.length} vertices, ${ply.faces.length} faces.');
  if (ply.faces.isEmpty) {
    stdout.writeln(
      'NOTE: input has no faces (point cloud). Re-capture a frontal scan with '
      'the updated app to get a triangulated mesh, then re-run this tool.',
    );
  }

  // Midline X = mean X of the symmetry-axis vertices (robust face centre).
  final double x0 = _midlineX(verts);
  // Reference half-width = furthest vertex from the midline along X.
  double halfSpan = 0;
  for (final _V3 v in verts) {
    final double d = (v.x - x0).abs();
    if (d > halfSpan) {
      halfSpan = d;
    }
  }
  if (halfSpan <= 0) {
    stderr.writeln('Degenerate X spread; cannot classify.');
    exit(65);
  }

  final double centerFrac = parsed.center;
  final double blendFrac = parsed.blend;

  final List<int> center = <int>[];
  final List<int> leftBlend = <int>[];
  final List<int> leftOuter = <int>[];
  final List<int> rightBlend = <int>[];
  final List<int> rightOuter = <int>[];

  // Per-vertex blend weight: 0 = pure frontal, 1 = pure side source. Ramps
  // linearly across the blend band so the merge transition is smooth.
  final List<double> sideWeight = List<double>.filled(verts.length, 0);

  for (int i = 0; i < verts.length; i++) {
    final double t = (verts[i].x - x0) / halfSpan; // ~[-1, 1]
    final double a = t.abs();
    if (a <= centerFrac) {
      center.add(i);
      sideWeight[i] = 0;
    } else if (a <= centerFrac + blendFrac) {
      (t < 0 ? leftBlend : rightBlend).add(i);
      sideWeight[i] = blendFrac <= 0
          ? 1
          : ((a - centerFrac) / blendFrac).clamp(0.0, 1.0);
    } else {
      (t < 0 ? leftOuter : rightOuter).add(i);
      sideWeight[i] = 1;
    }
  }

  final String out = parsed.out ?? _defaultOut;
  File(out).writeAsStringSync(
    _renderDart(
      source: parsed.plyPath!,
      vertexCount: verts.length,
      x0: x0,
      halfSpan: halfSpan,
      centerFrac: centerFrac,
      blendFrac: blendFrac,
      center: center,
      leftBlend: leftBlend,
      leftOuter: leftOuter,
      rightBlend: rightBlend,
      rightOuter: rightOuter,
      sideWeight: sideWeight,
    ),
  );

  // Colour-coded PLY for eyeballing the regions in MeshLab/CloudCompare.
  final List<List<int>> colorOf = List<List<int>>.filled(
    verts.length,
    _regionColors['center']!,
  );
  void paint(List<int> ids, List<int> rgb) {
    for (final int i in ids) {
      colorOf[i] = rgb;
    }
  }

  paint(leftOuter, _regionColors['leftOuter']!);
  paint(leftBlend, _regionColors['leftBlend']!);
  paint(rightBlend, _regionColors['rightBlend']!);
  paint(rightOuter, _regionColors['rightOuter']!);

  final String coloredOut = parsed.coloredOut ?? _defaultColoredPath(parsed.plyPath!);
  File(coloredOut).writeAsStringSync(_renderColoredPly(verts, colorOf, ply.faces));

  stdout
    ..writeln('Midline X = ${x0.toStringAsFixed(4)}  '
        'halfSpan = ${halfSpan.toStringAsFixed(4)} m')
    ..writeln('Regions (count):')
    ..writeln('  leftOuter  : ${leftOuter.length}')
    ..writeln('  leftBlend  : ${leftBlend.length}')
    ..writeln('  center     : ${center.length}')
    ..writeln('  rightBlend : ${rightBlend.length}')
    ..writeln('  rightOuter : ${rightOuter.length}')
    ..writeln('Wrote $out')
    ..writeln('Wrote $coloredOut  (open in MeshLab/CloudCompare to inspect)');
}

/// Region → RGB for the colour-coded PLY. Left = blue-ish, right = red-ish,
/// blends lighter, centre green.
const Map<String, List<int>> _regionColors = <String, List<int>>{
  'center': <int>[40, 200, 40],
  'leftBlend': <int>[0, 180, 200],
  'leftOuter': <int>[0, 90, 255],
  'rightBlend': <int>[255, 170, 0],
  'rightOuter': <int>[125, 45, 45],
};

String _defaultColoredPath(String plyPath) {
  final int dot = plyPath.lastIndexOf('.');
  final String base = dot > 0 ? plyPath.substring(0, dot) : plyPath;
  return '${base}_regions.ply';
}

String _renderColoredPly(
  List<_V3> verts,
  List<List<int>> colorOf,
  List<List<int>> faces,
) {
  final StringBuffer b = StringBuffer()
    ..writeln('ply')
    ..writeln('format ascii 1.0')
    ..writeln('comment flutter_face_scan region-coloured vertices')
    ..writeln('element vertex ${verts.length}')
    ..writeln('property float x')
    ..writeln('property float y')
    ..writeln('property float z')
    ..writeln('property uchar red')
    ..writeln('property uchar green')
    ..writeln('property uchar blue');
  if (faces.isNotEmpty) {
    b
      ..writeln('element face ${faces.length}')
      ..writeln('property list uchar int vertex_indices');
  }
  b.writeln('end_header');
  for (int i = 0; i < verts.length; i++) {
    final _V3 v = verts[i];
    final List<int> c = colorOf[i];
    b.writeln('${v.x} ${v.y} ${v.z} ${c[0]} ${c[1]} ${c[2]}');
  }
  for (final List<int> f in faces) {
    b.writeln('3 ${f[0]} ${f[1]} ${f[2]}');
  }
  return b.toString();
}

double _midlineX(List<_V3> verts) {
  double sum = 0;
  int n = 0;
  for (final int index in FaceSymmetryAxis.ordered) {
    if (index >= 0 && index < verts.length) {
      sum += verts[index].x;
      n++;
    }
  }
  return n == 0 ? 0 : sum / n;
}

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
    return const _Ply(<_V3>[], <List<int>>[]);
  }

  // Collect all non-empty data lines: first vCount are vertices, next fCount
  // are faces.
  final List<String> data = <String>[];
  for (int i = headerEnd + 1; i < lines.length; i++) {
    final String line = lines[i].trim();
    if (line.isNotEmpty) {
      data.add(line);
    }
  }

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

  final List<List<int>> faces = <List<int>>[];
  for (; idx < data.length && faces.length < fCount; idx++) {
    final List<String> parts = data[idx].split(RegExp(r'\s+'));
    // Expect "3 a b c" (triangles).
    if (parts.length >= 4 && parts[0] == '3') {
      final int? a = int.tryParse(parts[1]);
      final int? b = int.tryParse(parts[2]);
      final int? c = int.tryParse(parts[3]);
      if (a != null && b != null && c != null) {
        faces.add(<int>[a, b, c]);
      }
    }
  }

  return _Ply(verts, faces);
}

String _renderDart({
  required String source,
  required int vertexCount,
  required double x0,
  required double halfSpan,
  required double centerFrac,
  required double blendFrac,
  required List<int> center,
  required List<int> leftBlend,
  required List<int> leftOuter,
  required List<int> rightBlend,
  required List<int> rightOuter,
  required List<double> sideWeight,
}) {
  String listOf(String name, List<int> ids) =>
      '  static const List<int> $name = <int>[${ids.join(', ')}];';
  final String weights = sideWeight
      .map((double w) => w == 0 || w == 1 ? w.toStringAsFixed(0) : w.toStringAsFixed(3))
      .join(', ');

  return '''
// GENERATED by tool/generate_face_regions.dart — do not edit by hand.
// Source: $source
// vertexCount=$vertexCount, midlineX=${x0.toStringAsFixed(6)}, '''
      'halfSpan=${halfSpan.toStringAsFixed(6)}, '
      'center=$centerFrac, blend=$blendFrac\n'
      '''//
// "left" = negative local X, "right" = positive local X. If the on-device
// region colouring looks mirrored, swap the left/right mappings in the merge.

/// Which capture a vertex should be sourced from when merging the three views.
enum FaceRegion { leftOuter, leftBlend, center, rightBlend, rightOuter }

abstract final class FaceRegions {
  const FaceRegions._();

  static const int vertexCount = $vertexCount;

${listOf('center', center)}
${listOf('leftBlend', leftBlend)}
${listOf('leftOuter', leftOuter)}
${listOf('rightBlend', rightBlend)}
${listOf('rightOuter', rightOuter)}

  /// Per-vertex blend weight for the merge: 0 = take the frontal capture,
  /// 1 = take the side capture, values in between ramp across the blend band.
  static const List<double> sideWeight = <double>[$weights];

  /// Vertex index -> region (O(1) lookup), built once from the lists above.
  static final List<FaceRegion> byVertex = _buildLookup();

  /// Region for a vertex index; defaults to [FaceRegion.center] if out of range.
  static FaceRegion of(int vertexIndex) =>
      (vertexIndex >= 0 && vertexIndex < byVertex.length)
          ? byVertex[vertexIndex]
          : FaceRegion.center;

  static List<FaceRegion> _buildLookup() {
    final List<FaceRegion> out =
        List<FaceRegion>.filled(vertexCount, FaceRegion.center);
    for (final int i in leftOuter) {
      out[i] = FaceRegion.leftOuter;
    }
    for (final int i in leftBlend) {
      out[i] = FaceRegion.leftBlend;
    }
    for (final int i in rightBlend) {
      out[i] = FaceRegion.rightBlend;
    }
    for (final int i in rightOuter) {
      out[i] = FaceRegion.rightOuter;
    }
    return out;
  }
}
''';
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
  final List<List<int>> faces;
}

class _Args {
  const _Args({
    required this.plyPath,
    required this.center,
    required this.blend,
    required this.out,
    required this.coloredOut,
  });

  final String? plyPath;
  final double center;
  final double blend;
  final String? out;
  final String? coloredOut;
}

_Args _parseArgs(List<String> args) {
  String? ply;
  String? out;
  String? coloredOut;
  double center = 0.34;
  double blend = 0.12;
  for (final String arg in args) {
    if (arg.startsWith('--center=')) {
      center = double.tryParse(arg.substring('--center='.length)) ?? center;
    } else if (arg.startsWith('--blend=')) {
      blend = double.tryParse(arg.substring('--blend='.length)) ?? blend;
    } else if (arg.startsWith('--out=')) {
      out = arg.substring('--out='.length);
    } else if (arg.startsWith('--colored-out=')) {
      coloredOut = arg.substring('--colored-out='.length);
    } else if (!arg.startsWith('--')) {
      ply = arg;
    }
  }
  return _Args(
    plyPath: ply,
    center: center,
    blend: blend,
    out: out,
    coloredOut: coloredOut,
  );
}
