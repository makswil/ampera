import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:vector_math/vector_math_64.dart';

/// Zero non-frontal pose weights on [vertices] (+ optional hard halo).
///
/// Side stills capture a different gaze, so blending them into the eye *holes*
/// ghosts a second iris. Pin the aperture verts only — a periocular halo
/// stamps lids / lashes / dark circles as a hard island that crawls as the
/// expression mesh deforms. Mutates [weights] in place; `[0]` is frontal.
void pinVerticesToFrontalPose({
  required List<List<double>> weights,
  required List<Vector3> frontalVerts,
  required Iterable<int> vertices,
  Iterable<int> haloSeeds = const <int>[],
  double haloRadius = 0.012,
}) {
  if (weights.isEmpty) {
    return;
  }
  final List<double> frontal = weights[0];
  final Set<int> pin = <int>{...vertices};
  if (haloSeeds.isNotEmpty && haloRadius > 0) {
    expandPinHalo(
      pin: pin,
      seeds: haloSeeds,
      verts: frontalVerts,
      radius: haloRadius,
    );
  }
  for (final int vi in pin) {
    if (vi < 0 || vi >= frontal.length) {
      continue;
    }
    if (frontal[vi] < 1e-3) {
      frontal[vi] = 1.0;
    }
    for (int p = 1; p < weights.length; p++) {
      final List<double> w = weights[p];
      if (vi < w.length) {
        w[vi] = 0;
      }
    }
  }
}

/// Adds every vertex within [radius] of a seed into [pin].
void expandPinHalo({
  required Set<int> pin,
  required Iterable<int> seeds,
  required List<Vector3> verts,
  required double radius,
}) {
  final double r2 = radius * radius;
  for (final int seed in seeds) {
    if (seed < 0 || seed >= verts.length) {
      continue;
    }
    final Vector3 c = verts[seed];
    for (int i = 0; i < verts.length; i++) {
      if (pin.contains(i)) {
        continue;
      }
      if ((verts[i] - c).length2 <= r2) {
        pin.add(i);
      }
    }
  }
}

/// Lid verts that share triangles with [seeds], plus [rings] hops outward.
/// Topology-only (stable across expression frames) — not 3D distance.
Set<int> expandVertexRings({
  required Iterable<int> seeds,
  required List<int> triangles,
  int rings = 5,
}) {
  final Set<int> out = <int>{...seeds};
  if (rings <= 0 || triangles.length < 3) {
    return out;
  }
  final Map<int, List<int>> adj = <int, List<int>>{};
  void link(int a, int b) {
    (adj[a] ??= <int>[]).add(b);
    (adj[b] ??= <int>[]).add(a);
  }

  for (int t = 0; t + 2 < triangles.length; t += 3) {
    final int a = triangles[t];
    final int b = triangles[t + 1];
    final int c = triangles[t + 2];
    link(a, b);
    link(b, c);
    link(c, a);
  }

  Set<int> frontier = Set<int>.of(out);
  for (int r = 0; r < rings; r++) {
    final Set<int> next = <int>{};
    for (final int v in frontier) {
      final List<int>? nbrs = adj[v];
      if (nbrs == null) {
        continue;
      }
      for (final int n in nbrs) {
        if (out.add(n)) {
          next.add(n);
        }
      }
    }
    if (next.isEmpty) {
      break;
    }
    frontier = next;
  }
  return out;
}

/// Lid-margin iris ghosting: scale non-frontal weights by distance from [seeds].
///
/// Does **not** force frontal to 1 — lids / lashes / dark circles keep their
/// `n·v` mix. Side / chin-up fade to 0 at the aperture so a turned-head iris
/// cannot land on the hole or lash line. Smoothstep, not a binary ring.
///
/// Default radii: kill on the rim, full side contribution by ~5 mm (inside the
/// eyelid, short of the tear trough).
///
/// Kept for unit tests; production bake uses [pinVerticesToFrontalPose].
@visibleForTesting
void fadeNonFrontalNearSeeds({
  required List<List<double>> weights,
  required List<Vector3> verts,
  required Iterable<int> seeds,
  double innerRadius = 0,
  double outerRadius = 0.005,
}) {
  if (weights.length < 2 || outerRadius <= innerRadius || verts.isEmpty) {
    return;
  }
  final List<Vector3> seedPos = <Vector3>[
    for (final int i in seeds)
      if (i >= 0 && i < verts.length) verts[i],
  ];
  if (seedPos.isEmpty) {
    return;
  }
  final double span = outerRadius - innerRadius;
  final int n = verts.length;
  for (int i = 0; i < n; i++) {
    final Vector3 p = verts[i];
    double minD2 = double.infinity;
    for (final Vector3 s in seedPos) {
      final double d2 = (p - s).length2;
      if (d2 < minD2) {
        minD2 = d2;
      }
    }
    final double d = math.sqrt(minD2);
    final double keep;
    if (d <= innerRadius) {
      keep = 0;
    } else if (d >= outerRadius) {
      keep = 1;
    } else {
      final double t = ((d - innerRadius) / span).clamp(0.0, 1.0);
      keep = t * t * (3.0 - 2.0 * t);
    }
    if (keep >= 1) {
      continue;
    }
    for (int pIdx = 1; pIdx < weights.length; pIdx++) {
      final List<double> w = weights[pIdx];
      if (i < w.length) {
        w[i] *= keep;
      }
    }
  }
}
