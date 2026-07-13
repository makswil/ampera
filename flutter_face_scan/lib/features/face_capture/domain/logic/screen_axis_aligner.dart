import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../entities/screen_alignment.dart';

/// Fits the symmetry axis in 2D normalized screen space and reports how
/// straight / upright / centred it is.
///
/// Pure maths (2×2 total-least-squares via the covariance matrix), so it is
/// fully unit-testable with hand-built point lists.
final class ScreenAxisAligner {
  const ScreenAxisAligner({this.minSamples = 6});

  /// Minimum projected points required to attempt a fit.
  final int minSamples;

  /// Returns the 2D alignment, or null if too few points.
  ScreenAlignment? evaluate(List<Vector2> points) {
    if (points.length < minSamples) {
      return null;
    }

    // Centroid.
    double cx = 0;
    double cy = 0;
    for (final Vector2 p in points) {
      cx += p.x;
      cy += p.y;
    }
    cx /= points.length;
    cy /= points.length;

    // 2×2 covariance of the centred points.
    double sxx = 0;
    double sxy = 0;
    double syy = 0;
    for (final Vector2 p in points) {
      final double dx = p.x - cx;
      final double dy = p.y - cy;
      sxx += dx * dx;
      sxy += dx * dy;
      syy += dy * dy;
    }

    // Dominant eigenvector of [[sxx, sxy], [sxy, syy]] (closed form) → line dir.
    final double trace = sxx + syy;
    final double diff = sxx - syy;
    final double lambda = trace / 2 + math.sqrt((diff * diff) / 4 + sxy * sxy);
    final Vector2 direction = sxy.abs() > 1e-9
        ? Vector2(lambda - syy, sxy)
        : (sxx >= syy ? Vector2(1, 0) : Vector2(0, 1));
    direction.normalize();

    // Tilt from vertical (screen Y), using |dir| so it's orientation-agnostic.
    final double tilt =
        math.atan2(direction.x.abs(), direction.y.abs()) * 180 / math.pi;

    // Mean perpendicular residual.
    double residual = 0;
    for (final Vector2 p in points) {
      final double dx = p.x - cx;
      final double dy = p.y - cy;
      final double along = dx * direction.x + dy * direction.y;
      final double projX = direction.x * along;
      final double projY = direction.y * along;
      residual += math.sqrt(
        (dx - projX) * (dx - projX) + (dy - projY) * (dy - projY),
      );
    }
    residual /= points.length;

    return ScreenAlignment(
      tiltDegrees: tilt,
      straightness: residual,
      centerOffsetX: cx - 0.5,
      centerOffsetY: cy - 0.5,
    );
  }
}
