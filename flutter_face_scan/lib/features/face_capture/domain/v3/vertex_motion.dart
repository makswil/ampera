import 'package:vector_math/vector_math_64.dart';

/// Face-local vertex travel vs a rest (neutral) mesh. Units are metres
/// (ARKit face-local). Used to decide where a static L/R still may paint
/// without smearing a smile.

/// Below this, the vertex is treated as rigid enough for a support still.
/// 2 mm — nose wings / temples typically stay under this in a smile.
const double kMotionStillMax = 0.002;

/// At/above this the vertex is expression-driven — clip JPEG only.
/// 8 mm — mouth corners in a moderate smile.
const double kMotionMovingMin = 0.008;

/// Displacement that maps to white in the motion heatmap (20 mm).
const double kMotionHeatScale = 0.020;

enum MotionQuality {
  /// < [kMotionStillMax] — support stills may paint here.
  still,

  /// [kMotionStillMax] … [kMotionMovingMin] — soft zone.
  slight,

  /// ≥ [kMotionMovingMin] — clip only.
  moving,
}

MotionQuality motionQuality(double meters) {
  if (meters < kMotionStillMax) {
    return MotionQuality.still;
  }
  if (meters < kMotionMovingMin) {
    return MotionQuality.slight;
  }
  return MotionQuality.moving;
}

/// 1 = support stills may paint (still), 0 = clip only (moving), smoothstep
/// across [kMotionStillMax, kMotionMovingMin].
double motionAllowSupport(double meters) {
  if (meters <= kMotionStillMax) {
    return 1;
  }
  if (meters >= kMotionMovingMin) {
    return 0;
  }
  final double t =
      ((meters - kMotionStillMax) / (kMotionMovingMin - kMotionStillMax))
          .clamp(0.0, 1.0);
  final double s = t * t * (3.0 - 2.0 * t);
  return 1.0 - s;
}

/// Mean of index-aligned vertex lists. Null if [sources] is empty.
List<Vector3>? meanVertices(List<List<Vector3>> sources) {
  if (sources.isEmpty) {
    return null;
  }
  int n = sources.first.length;
  for (final List<Vector3> s in sources) {
    if (s.length < n) {
      n = s.length;
    }
  }
  if (n == 0) {
    return null;
  }
  final List<Vector3> out = List<Vector3>.generate(
    n,
    (_) => Vector3.zero(),
    growable: false,
  );
  for (final List<Vector3> s in sources) {
    for (int i = 0; i < n; i++) {
      out[i].add(s[i]);
    }
  }
  final double inv = 1.0 / sources.length;
  for (final Vector3 v in out) {
    v.scale(inv);
  }
  return out;
}

/// Per-vertex max travel of [clips] away from [rest] (Euclidean, metres).
List<double> maxVertexTravel({
  required List<Vector3> rest,
  required List<List<Vector3>> clips,
}) {
  final int n = rest.length;
  final List<double> out = List<double>.filled(n, 0);
  for (final List<Vector3> clip in clips) {
    final int m = clip.length < n ? clip.length : n;
    for (int i = 0; i < m; i++) {
      final double d = (clip[i] - rest[i]).length;
      if (d > out[i]) {
        out[i] = d;
      }
    }
  }
  return out;
}
