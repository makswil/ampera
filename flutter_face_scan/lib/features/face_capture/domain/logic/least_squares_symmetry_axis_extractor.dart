import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../constants/face_vertex_indices.dart';
import '../entities/face_observation.dart';
import '../entities/symmetry_axis.dart';
import '../services/symmetry_axis_extractor.dart';

/// Fits the symmetry axis with a 3D total-least-squares line fit.
///
/// Algorithm (all pure maths — deterministic, no I/O, fully unit-testable):
///   1. Gather the forehead→chin vertices ([FaceSymmetryAxis.ordered]).
///   2. Compute the centroid → axis [SymmetryAxis.origin].
///   3. Compute the 3×3 covariance matrix of the centred points.
///   4. Take its dominant eigenvector (power iteration) → line [direction].
///   5. Orient the direction forehead→chin and measure in-plane [tiltDegrees]
///      plus the mean orthogonal [residual].
final class LeastSquaresSymmetryAxisExtractor implements SymmetryAxisExtractor {
  const LeastSquaresSymmetryAxisExtractor({
    this.minSamples = 6,
    this.powerIterations = 32,
  });

  /// Minimum usable vertices required to attempt a fit.
  final int minSamples;

  /// Power-iteration steps for the dominant eigenvector. 32 is ample for a
  /// well-separated principal axis like a face midline.
  final int powerIterations;

  @override
  SymmetryAxis? extract(FaceObservation observation) {
    if (!observation.isTracked) {
      return null;
    }

    final List<Vector3> points = observation.verticesAt(
      FaceSymmetryAxis.ordered,
    );
    if (points.length < minSamples) {
      return null;
    }

    final Vector3 centroid = _centroid(points);
    final Matrix3 covariance = _covariance(points, centroid);
    final Vector3 direction = _dominantEigenvector(covariance)..normalize();
    _orientForeheadToChin(direction, points, centroid);

    return SymmetryAxis(
      origin: centroid,
      direction: direction,
      tiltDegrees: _inPlaneTilt(direction),
      residual: _meanResidual(points, centroid, direction),
      sampleCount: points.length,
    );
  }

  Vector3 _centroid(List<Vector3> points) {
    final Vector3 sum = Vector3.zero();
    for (final Vector3 p in points) {
      sum.add(p);
    }
    return sum..scale(1.0 / points.length);
  }

  Matrix3 _covariance(List<Vector3> points, Vector3 centroid) {
    final Matrix3 c = Matrix3.zero();
    for (final Vector3 p in points) {
      final Vector3 d = p - centroid;
      c
        ..setEntry(0, 0, c.entry(0, 0) + d.x * d.x)
        ..setEntry(0, 1, c.entry(0, 1) + d.x * d.y)
        ..setEntry(0, 2, c.entry(0, 2) + d.x * d.z)
        ..setEntry(1, 1, c.entry(1, 1) + d.y * d.y)
        ..setEntry(1, 2, c.entry(1, 2) + d.y * d.z)
        ..setEntry(2, 2, c.entry(2, 2) + d.z * d.z);
    }
    // Mirror the symmetric lower triangle.
    c
      ..setEntry(1, 0, c.entry(0, 1))
      ..setEntry(2, 0, c.entry(0, 2))
      ..setEntry(2, 1, c.entry(1, 2));
    return c;
  }

  /// Dominant eigenvector via power iteration. Seeded along +Y (faces are
  /// near-vertical) to converge fast and avoid a zero-projection seed.
  Vector3 _dominantEigenvector(Matrix3 covariance) {
    Vector3 v = Vector3(0.0, 1.0, 0.0);
    for (int i = 0; i < powerIterations; i++) {
      final Vector3 next = covariance.transformed(v);
      final double len = next.length;
      if (len <= 1e-12) {
        return Vector3(0.0, 1.0, 0.0);
      }
      v = next..scale(1.0 / len);
    }
    return v;
  }

  void _orientForeheadToChin(
    Vector3 direction,
    List<Vector3> points,
    Vector3 centroid,
  ) {
    // points[0] is the forehead, points.last the chin (table is ordered).
    final Vector3 foreheadToChin = points.last - points.first;
    if (direction.dot(foreheadToChin) < 0) {
      direction.scale(-1.0);
    }
  }

  /// In-plane tilt from screen-vertical (+Y), measured in the X–Y plane.
  /// 0° = upright. Sign matches the roll convention (+ = tilt to user's left).
  double _inPlaneTilt(Vector3 direction) {
    final double radians = math.atan2(direction.x, direction.y.abs());
    return radians * 180.0 / math.pi;
  }

  double _meanResidual(
    List<Vector3> points,
    Vector3 centroid,
    Vector3 direction,
  ) {
    double total = 0.0;
    for (final Vector3 p in points) {
      final Vector3 d = p - centroid;
      // Orthogonal distance = |d − (d·û)û|.
      final Vector3 projected = direction * d.dot(direction);
      total += (d - projected).length;
    }
    return total / points.length;
  }
}
