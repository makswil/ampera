import 'package:vector_math/vector_math_64.dart';

/// Zero non-frontal pose weights on [vertices] (+ optional periocular halo).
///
/// Side / chin-up stills capture a different gaze, so blending them into the
/// eye holes ghosts a second iris onto the lids. Pinning those verts to the
/// frontal still keeps one pupil. Mutates [weights] in place; `[0]` is frontal.
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
