import 'package:vector_math/vector_math_64.dart';

/// Area-weighted per-vertex normals (smooth shading; geometry unchanged).
/// Negate the cross product if a renderer shows inverted lighting.
List<Vector3> computeVertexNormals(
  List<Vector3> vertices,
  List<int> triangles,
) {
  final List<Vector3> normals = List<Vector3>.generate(
    vertices.length,
    (_) => Vector3.zero(),
    growable: false,
  );

  for (int i = 0; i + 2 < triangles.length; i += 3) {
    final int a = triangles[i];
    final int b = triangles[i + 1];
    final int c = triangles[i + 2];
    if (a >= vertices.length || b >= vertices.length || c >= vertices.length) {
      continue;
    }
    // Unnormalized cross product == 2·area·unit-normal → area-weighted accumulate.
    final Vector3 faceNormal =
        (vertices[b] - vertices[a]).cross(vertices[c] - vertices[a]);
    normals[a].add(faceNormal);
    normals[b].add(faceNormal);
    normals[c].add(faceNormal);
  }

  for (final Vector3 n in normals) {
    if (n.length2 > 0) {
      n.normalize();
    }
  }
  return normals;
}

/// Sets each cap centroid's normal (index `baseIndex + i`) to the mean of its
/// rim normals. Call with [normals] built from ORIGINAL triangles only, so cap
/// faces don't crease the rim (no "eyeliner" seam).
// REDUNDANT(eye-fill): only used by obsolete hole_filler centroid caps. Safe to
// delete with hole_filler.dart.
void assignCapNormals(
  List<Vector3> normals,
  List<List<int>> loops,
  int baseIndex,
) {
  for (int i = 0; i < loops.length; i++) {
    final Vector3 n = Vector3.zero();
    for (final int vi in loops[i]) {
      n.add(normals[vi]);
    }
    if (n.length2 > 0) {
      n.normalize();
    }
    normals[baseIndex + i] = n;
  }
}
