import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart';

import '../../domain/constants/face_regions.g.dart';
import '../../domain/v3/hole_filler.dart';
import '../../domain/v3/texture_projection.dart';

/// One pose ready for baking: RGB still, its face-local vertices (index-aligned
/// across poses), and the projection into that still.
final class BakePose {
  BakePose({
    required this.image,
    required this.vertices,
    required this.projection,
  });

  final img.Image image;
  final List<Vector3> vertices;
  final PoseProjection projection;
}

/// [pose] with the per-loop cap centroid vertices appended (same image/projection).
BakePose bakePoseWithCaps(BakePose pose, List<List<int>> loops) => BakePose(
      image: pose.image,
      vertices: <Vector3>[
        ...pose.vertices,
        ...capVertices(loops, pose.vertices),
      ],
      projection: pose.projection,
    );

/// Bakes the face texture (ARKit UV atlas) from the three poses: per texel →
/// covering triangle → face-local point → project into the photos → blend
/// frontal↔side by [FaceRegions.sideWeight]. Output PNG is top-left origin. Pure.
final class TextureBaker {
  const TextureBaker();

  img.Image bake({
    required BakePose frontal,
    required BakePose left,
    required BakePose right,
    required List<double> uvs,
    required List<int> triangles,
    int textureSize = 2048,
  }) {
    final img.Image out = img.Image(
      width: textureSize,
      height: textureSize,
      numChannels: 4,
    );

    // UV → texture-pixel (top-left origin), one per vertex.
    final List<Vector2> uvPx = <Vector2>[
      for (int i = 0; i + 1 < uvs.length; i += 2)
        Vector2(uvs[i] * textureSize, uvs[i + 1] * textureSize),
    ];

    for (int t = 0; t + 2 < triangles.length; t += 3) {
      final int a = triangles[t];
      final int b = triangles[t + 1];
      final int c = triangles[t + 2];
      if (a >= uvPx.length || b >= uvPx.length || c >= uvPx.length) {
        continue;
      }
      _rasterizeTriangle(out, frontal, left, right, uvPx[a], uvPx[b], uvPx[c],
          a, b, c, textureSize);
    }

    return out;
  }

  void _rasterizeTriangle(
    img.Image out,
    BakePose frontal,
    BakePose left,
    BakePose right,
    Vector2 uvA,
    Vector2 uvB,
    Vector2 uvC,
    int a,
    int b,
    int c,
    int size,
  ) {
    final int minX = math.max(0, _floor3(uvA.x, uvB.x, uvC.x));
    final int maxX = math.min(size - 1, _ceil3(uvA.x, uvB.x, uvC.x));
    final int minY = math.max(0, _floor3(uvA.y, uvB.y, uvC.y));
    final int maxY = math.min(size - 1, _ceil3(uvA.y, uvB.y, uvC.y));
    if (minX > maxX || minY > maxY) {
      return;
    }

    // Per-texel blend weight (frontal↔side) and the left/right source pick.
    final double wa = _sideWeight(a);
    final double wb = _sideWeight(b);
    final double wc = _sideWeight(c);
    final BakePose side = _pickSide(a, b, c, left, right);

    for (int py = minY; py <= maxY; py++) {
      for (int px = minX; px <= maxX; px++) {
        final Vector2 p = Vector2(px + 0.5, py + 0.5);
        final Vector3? bc = barycentric(p, uvA, uvB, uvC);
        if (bc == null || bc.x < 0 || bc.y < 0 || bc.z < 0) {
          continue;
        }

        final _Rgb? front = _sampleFace(frontal, bc, a, b, c);
        if (front == null) {
          continue; // no frontal colour → leave hole (dilation is a later pass)
        }

        final double w = bc.x * wa + bc.y * wb + bc.z * wc;
        _Rgb colour = front;
        if (w > 0) {
          final _Rgb? sideColour = _sampleFace(side, bc, a, b, c);
          if (sideColour != null) {
            colour = _lerp(front, sideColour, w);
          }
        }

        out.setPixelRgba(px, py, colour.r, colour.g, colour.b, 255);
      }
    }
  }

  /// Interpolates the face-local point at [bc] across the pose's own vertices,
  /// projects it into that pose's still and bilinearly samples the colour.
  _Rgb? _sampleFace(BakePose pose, Vector3 bc, int a, int b, int c) {
    final Vector3 p = pose.vertices[a] * bc.x +
        pose.vertices[b] * bc.y +
        pose.vertices[c] * bc.z;
    final Vector2? pixel = pose.projection.projectPixel(p);
    if (pixel == null) {
      return null;
    }
    return _sampleBilinear(pose.image, pixel.x, pixel.y);
  }

  /// Picks the left or right side capture by which side's regions cover more of
  /// the triangle's vertices (matches merge_regions' per-vertex file choice).
  BakePose _pickSide(int a, int b, int c, BakePose left, BakePose right) {
    int leftVotes = 0;
    for (final int i in <int>[a, b, c]) {
      final FaceRegion region = FaceRegions.of(i);
      if (region == FaceRegion.leftOuter || region == FaceRegion.leftBlend) {
        leftVotes++;
      }
    }
    return leftVotes >= 2 ? left : right;
  }

  double _sideWeight(int i) =>
      (i >= 0 && i < FaceRegions.sideWeight.length) ? FaceRegions.sideWeight[i] : 0;

  _Rgb _lerp(_Rgb a, _Rgb b, double t) => _Rgb(
        (a.r + (b.r - a.r) * t).round().clamp(0, 255),
        (a.g + (b.g - a.g) * t).round().clamp(0, 255),
        (a.b + (b.b - a.b) * t).round().clamp(0, 255),
      );

  _Rgb? _sampleBilinear(img.Image image, double x, double y) {
    if (x < 0 || y < 0 || x > image.width - 1 || y > image.height - 1) {
      return null;
    }
    final int x0 = x.floor();
    final int y0 = y.floor();
    final int x1 = math.min(x0 + 1, image.width - 1);
    final int y1 = math.min(y0 + 1, image.height - 1);
    final double fx = x - x0;
    final double fy = y - y0;

    final img.Pixel p00 = image.getPixel(x0, y0);
    final img.Pixel p10 = image.getPixel(x1, y0);
    final img.Pixel p01 = image.getPixel(x0, y1);
    final img.Pixel p11 = image.getPixel(x1, y1);

    double lerp(double a, double b, double f) => a + (b - a) * f;
    double chan(num a, num b, num c, num d) => lerp(
          lerp(a.toDouble(), b.toDouble(), fx),
          lerp(c.toDouble(), d.toDouble(), fx),
          fy,
        );

    return _Rgb(
      chan(p00.r, p10.r, p01.r, p11.r).round().clamp(0, 255),
      chan(p00.g, p10.g, p01.g, p11.g).round().clamp(0, 255),
      chan(p00.b, p10.b, p01.b, p11.b).round().clamp(0, 255),
    );
  }

  int _floor3(double a, double b, double c) => math.min(a, math.min(b, c)).floor();
  int _ceil3(double a, double b, double c) => math.max(a, math.max(b, c)).ceil();
}

/// Small 8-bit RGB triple (avoids per-texel `img.Color` allocation churn).
final class _Rgb {
  const _Rgb(this.r, this.g, this.b);
  final int r;
  final int g;
  final int b;
}
