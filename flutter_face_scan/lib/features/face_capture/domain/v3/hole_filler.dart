import 'package:vector_math/vector_math_64.dart';

// REDUNDANT(eye-fill): entire file obsolete — bake now appends
// FaceHoleGeometry.eyeTriangles only. Safe to delete with hole_filler_test.dart.

/// Caps ARKit's open eye/mouth mesh holes (gaps in the topology) so they can be
/// textured. Pure; shared by app + bake tool.

/// Ordered vertex loops of open boundaries: a directed edge `u→v` is a rim when
/// its reverse `v→u` is absent.
// REDUNDANT(eye-fill)
List<List<int>> findBoundaryLoops(List<int> triangles) {
  const int stride = 1 << 20; // > any vertex index; encodes (u,v) as u*stride+v
  final Set<int> directed = <int>{};
  for (int i = 0; i + 2 < triangles.length; i += 3) {
    final List<int> t = <int>[triangles[i], triangles[i + 1], triangles[i + 2]];
    for (int k = 0; k < 3; k++) {
      directed.add(t[k] * stride + t[(k + 1) % 3]);
    }
  }

  // Successor of each rim vertex (one outgoing rim edge on a manifold boundary).
  final Map<int, int> next = <int, int>{};
  for (final int code in directed) {
    final int u = code ~/ stride;
    final int v = code % stride;
    if (!directed.contains(v * stride + u)) {
      next[u] = v;
    }
  }

  final List<List<int>> loops = <List<int>>[];
  final Set<int> visited = <int>{};
  for (final int start in next.keys) {
    if (visited.contains(start)) {
      continue;
    }
    final List<int> loop = <int>[];
    int? cur = start;
    while (cur != null && !visited.contains(cur) && next.containsKey(cur)) {
      visited.add(cur);
      loop.add(cur);
      cur = next[cur];
    }
    if (loop.length >= 3) {
      loops.add(loop);
    }
  }
  return loops;
}

/// Interior holes (eyes, mouth) only: drops the largest-UV-area loop, which is
/// the outer face silhouette (capping it would fan over the whole mask).
// REDUNDANT(eye-fill)
List<List<int>> innerHoleLoops(List<List<int>> loops, List<double> uvs) {
  if (loops.length <= 1) {
    return const <List<int>>[]; // only the outer boundary → nothing to cap
  }
  double areaOf(List<int> loop) {
    double minU = double.infinity, maxU = -double.infinity;
    double minV = double.infinity, maxV = -double.infinity;
    for (final int vi in loop) {
      final double u = uvs[vi * 2];
      final double v = uvs[vi * 2 + 1];
      if (u < minU) minU = u;
      if (u > maxU) maxU = u;
      if (v < minV) minV = v;
      if (v > maxV) maxV = v;
    }
    return (maxU - minU) * (maxV - minV);
  }

  int outer = 0;
  double outerArea = areaOf(loops[0]);
  for (int i = 1; i < loops.length; i++) {
    final double a = areaOf(loops[i]);
    if (a > outerArea) {
      outerArea = a;
      outer = i;
    }
  }
  return <List<int>>[
    for (int i = 0; i < loops.length; i++)
      if (i != outer) loops[i],
  ];
}

/// Position-independent cap geometry. Loop `i`'s centroid vertex = `baseIndex + i`.
// REDUNDANT(eye-fill)
final class CapGeometry {
  const CapGeometry({required this.triangles, required this.uvs});

  /// Flat `[a,b,c, …]` cap triangles, referencing existing + centroid indices.
  final List<int> triangles;

  /// Flat `[u,v, …]` UVs for the centroid vertices, in loop order.
  final List<double> uvs;
}

/// Fan triangles + centroid UVs (mean of each loop's UVs) for [loops].
// REDUNDANT(eye-fill)
CapGeometry buildCapGeometry(
  List<List<int>> loops,
  List<double> uvs,
  int baseIndex,
) {
  final List<int> triangles = <int>[];
  final List<double> capUvs = <double>[];
  for (int li = 0; li < loops.length; li++) {
    final List<int> loop = loops[li];
    final int centroid = baseIndex + li;

    double su = 0;
    double sv = 0;
    for (final int vi in loop) {
      su += uvs[vi * 2];
      sv += uvs[vi * 2 + 1];
    }
    capUvs..add(su / loop.length)..add(sv / loop.length);

    // Fan: each rim edge + the centroid, preserving the rim winding.
    for (int i = 0; i < loop.length; i++) {
      triangles
        ..add(loop[i])
        ..add(loop[(i + 1) % loop.length])
        ..add(centroid);
    }
  }
  return CapGeometry(triangles: triangles, uvs: capUvs);
}

/// Projects each rim vertex of [loops] onto that loop's Newell plane (in place).
///
/// ARKit's eye sockets recess the eyelid ring into the skull; flattening the
/// ring (and then capping flat) removes the "eyes pushed into the face" look.
// REDUNDANT(eye-fill)
void flattenHoleRims(List<List<int>> loops, List<Vector3> vertices) {
  for (final List<int> loop in loops) {
    final ({Vector3 centroid, Vector3 normal})? plane =
        _loopPlane(loop, vertices);
    if (plane == null) {
      continue;
    }
    final Vector3 n = plane.normal;
    final Vector3 c = plane.centroid;
    for (final int vi in loop) {
      final Vector3 v = vertices[vi];
      // Orthogonal projection onto the plane through the centroid.
      v.sub(n * n.dot(v - c));
    }
  }
}

/// Per-pose cap vertex positions: each loop centroid on the (optionally
/// flattened) rim plane. [depthFactor] × loop radius insets into the socket
/// (0 = flat, the default — recessed caps look like sunken eyes).
// REDUNDANT(eye-fill)
List<Vector3> capVertices(
  List<List<int>> loops,
  List<Vector3> vertices, {
  double depthFactor = 0,
}) {
  return <Vector3>[
    for (final List<int> loop in loops) _capVertex(loop, vertices, depthFactor),
  ];
}

// REDUNDANT(eye-fill)
Vector3 _capVertex(List<int> loop, List<Vector3> vertices, double depthFactor) {
  final ({Vector3 centroid, Vector3 normal})? plane =
      _loopPlane(loop, vertices);
  if (plane == null) {
    final Vector3 fallback = Vector3.zero();
    for (final int vi in loop) {
      fallback.add(vertices[vi]);
    }
    fallback.scale(1.0 / loop.length);
    return fallback;
  }
  if (depthFactor == 0) {
    return Vector3.copy(plane.centroid);
  }

  // Mean rim radius.
  double radius = 0;
  for (final int vi in loop) {
    radius += (vertices[vi] - plane.centroid).length;
  }
  radius /= loop.length;

  // + = into the socket (loop winding makes Newell normal point inward).
  return plane.centroid + plane.normal * (depthFactor * radius);
}

/// Newell plane for [loop]: centroid + unit normal. Null if degenerate.
// REDUNDANT(eye-fill)
({Vector3 centroid, Vector3 normal})? _loopPlane(
  List<int> loop,
  List<Vector3> vertices,
) {
  final Vector3 centroid = Vector3.zero();
  for (final int vi in loop) {
    centroid.add(vertices[vi]);
  }
  centroid.scale(1.0 / loop.length);

  final Vector3 normal = Vector3.zero();
  for (int i = 0; i < loop.length; i++) {
    final Vector3 cur = vertices[loop[i]];
    final Vector3 nxt = vertices[loop[(i + 1) % loop.length]];
    normal
      ..x += (cur.y - nxt.y) * (cur.z + nxt.z)
      ..y += (cur.z - nxt.z) * (cur.x + nxt.x)
      ..z += (cur.x - nxt.x) * (cur.y + nxt.y);
  }
  if (normal.length2 == 0) {
    return null;
  }
  normal.normalize();
  return (centroid: centroid, normal: normal);
}
