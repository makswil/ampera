import 'package:vector_math/vector_math_64.dart';

/// Projects a face-local vertex into a pose's still image. Pure/testable.
///
/// clip = projection · view · faceTransform · [v,1]; NDC = clip/w (y up); pixel
/// origin top-left (y flipped). The one place to tune a flipped/mirrored bake.
final class PoseProjection {
  PoseProjection({
    required this.width,
    required this.height,
    required Matrix4 viewMatrix,
    required Matrix4 projectionMatrix,
    required Matrix4 faceTransform,
  }) : _mvp =
            projectionMatrix.multiplied(viewMatrix).multiplied(faceTransform);

  /// Pixel size of the target image.
  final int width;
  final int height;

  /// Combined face-local → clip transform (precomputed once).
  final Matrix4 _mvp;

  /// Pixel for [faceLocal] (top-left origin). Null if behind the camera; the
  /// pixel may still be outside the image — caller decides.
  Vector2? projectPixel(Vector3 faceLocal) {
    final Vector4 clip = _mvp.transform(
      Vector4(faceLocal.x, faceLocal.y, faceLocal.z, 1),
    );
    if (clip.w <= 0) {
      return null;
    }
    final double ndcX = clip.x / clip.w;
    final double ndcY = clip.y / clip.w;
    final double px = (ndcX * 0.5 + 0.5) * width;
    final double py = (1 - (ndcY * 0.5 + 0.5)) * height;
    return Vector2(px, py);
  }
}

/// Barycentric (u,v,w) of [p] in triangle (a,b,c); inside iff all ≥ 0. Null if
/// degenerate.
Vector3? barycentric(Vector2 p, Vector2 a, Vector2 b, Vector2 c) {
  final Vector2 v0 = b - a;
  final Vector2 v1 = c - a;
  final Vector2 v2 = p - a;
  final double den = v0.x * v1.y - v1.x * v0.y;
  if (den == 0) {
    return null;
  }
  final double v = (v2.x * v1.y - v1.x * v2.y) / den;
  final double w = (v0.x * v2.y - v2.x * v0.y) / den;
  final double u = 1.0 - v - w;
  return Vector3(u, v, w);
}
