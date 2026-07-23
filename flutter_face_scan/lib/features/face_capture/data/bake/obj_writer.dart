import 'package:vector_math/vector_math_64.dart';

/// Wavefront OBJ + MTL for a textured mesh. Pure; shared by app + tool.
/// `vt` = `(u, 1-v)` (PNG is top-left origin, OBJ samples bottom-left). `vn`
/// emitted only when [normals] is non-empty.
String renderObj({
  required List<Vector3> vertices,
  required List<double> uvs,
  required List<Vector3> normals,
  required List<int> triangles,
  required String materialName,
  required String mtlName,
}) {
  final bool hasNormals = normals.isNotEmpty;
  final StringBuffer b = StringBuffer()
    ..writeln('# flutter_face_scan baked face')
    ..writeln('mtllib $mtlName')
    ..writeln('o face');
  for (final Vector3 v in vertices) {
    b.writeln('v ${v.x} ${v.y} ${v.z}');
  }
  for (int i = 0; i + 1 < uvs.length; i += 2) {
    b.writeln('vt ${uvs[i]} ${1 - uvs[i + 1]}');
  }
  if (hasNormals) {
    for (final Vector3 n in normals) {
      b.writeln('vn ${n.x} ${n.y} ${n.z}');
    }
  }
  b.writeln('usemtl $materialName');
  // Per-vertex UV + normal share the vertex index, so face refs are v/vt[/vn].
  for (int i = 0; i + 2 < triangles.length; i += 3) {
    final int a = triangles[i] + 1;
    final int c = triangles[i + 1] + 1;
    final int d = triangles[i + 2] + 1;
    if (hasNormals) {
      b.writeln('f $a/$a/$a $c/$c/$c $d/$d/$d');
    } else {
      b.writeln('f $a/$a $c/$c $d/$d');
    }
  }
  return b.toString();
}

/// MTL pointing [materialName] at the baked albedo [pngName], and optionally a
/// normal map [normalPngName].
///
/// Uses `map_Kn` (Blender / tools that expect a normal map). Deliberately does
/// **not** set `map_Bump`: many viewers treat bump as a height/luma multiply and
/// wash the whole face out with a pale veil when given an RGB normal atlas.
String renderMtl({
  required String materialName,
  required String pngName,
  String? normalPngName,
}) {
  final StringBuffer b = StringBuffer()
    ..writeln('newmtl $materialName')
    ..writeln('Ka 1.0 1.0 1.0')
    ..writeln('Kd 1.0 1.0 1.0')
    ..writeln('map_Kd $pngName');
  if (normalPngName != null) {
    b.writeln('map_Kn $normalPngName');
  }
  return b.toString();
}