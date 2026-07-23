import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart';

import '../../domain/constants/face_regions.g.dart';
import '../../domain/v3/hole_filler.dart';
import '../../domain/v3/texture_projection.dart';

/// One pose ready for baking: RGB still, its face-local vertices (index-aligned
/// across poses), the projection into that still, and the raw view/face
/// matrices needed for view-dependent (`n·v`) weighting.
final class BakePose {
  BakePose({
    required this.image,
    required this.vertices,
    required this.projection,
    required this.viewMatrix,
    required this.faceTransform,
  });

  final img.Image image;
  final List<Vector3> vertices;
  final PoseProjection projection;

  /// World→camera (column-major, `vector_math_64`); camera world position is its
  /// inverse's translation.
  final Matrix4 viewMatrix;

  /// Face-local→world, rigid (rotation+translation, no scale) → the rotation
  /// part maps face-local normals to world.
  final Matrix4 faceTransform;
}

/// [pose] with hole rims flattened onto each loop's plane, then flat cap
/// centroids appended (same image/matrices). Copies verts so the source pose
/// stays unchanged.
BakePose bakePoseWithCaps(BakePose pose, List<List<int>> loops) {
  final List<Vector3> verts = <Vector3>[
    for (final Vector3 v in pose.vertices) Vector3.copy(v),
  ];
  // Eye/mouth rings share one depth → flat openings (ARKit sockets recess them).
  flattenHoleRims(loops, verts);
  return BakePose(
    image: pose.image,
    vertices: <Vector3>[
      ...verts,
      ...capVertices(loops, verts), // depthFactor 0 = flat with the rim plane
    ],
    projection: pose.projection,
    viewMatrix: pose.viewMatrix,
    faceTransform: pose.faceTransform,
  );
}

/// A [BakePose] paired with its per-vertex view-dependent weight (guarded
/// `n·v`), index-aligned with [BakePose.vertices]. See
/// `domain/v3/view_weights.dart`.
final class WeightedPose {
  const WeightedPose({
    required this.pose,
    required this.weight,
    this.gain = const <double>[1, 1, 1],
  });

  final BakePose pose;

  /// Per-vertex weight (0 = don't use this pose here), length ==
  /// `pose.vertices.length`.
  final List<double> weight;

  /// Per-channel RGB multiplier applied to this pose's samples to match the
  /// reference (frontal) exposure/white-balance. `[1,1,1]` = no correction.
  /// See [TextureBaker.poseGain].
  final List<double> gain;
}

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
    BakePose? up,
    List<double> downWeight = const <double>[],
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
      _rasterizeTriangle(out, frontal, left, right, up, downWeight, uvPx[a],
          uvPx[b], uvPx[c], a, b, c, textureSize);
    }

    return out;
  }

  /// View-dependent bake: per texel, choose colour from [poses] by their
  /// per-vertex weight (guarded `n·v`). Replaces the static region tables.
  ///
  /// [blend] `true` (default) = weighted average across the poses that cover the
  /// texel (smooth seams, slightly softer). `false` = best-only: take the single
  /// highest-weight pose (maximally sharp, but visible seams where the winner
  /// switches — pair with colour matching). The FIRST pose is the fallback
  /// (frontal) when no pose has weight there. Pure.
  img.Image bakeViewDependent({
    required List<WeightedPose> poses,
    required List<double> uvs,
    required List<int> triangles,
    int textureSize = 2048,
    bool blend = true,
  }) {
    final img.Image out = img.Image(
      width: textureSize,
      height: textureSize,
      numChannels: 4,
    );
    if (poses.isEmpty) {
      return out;
    }

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
      _rasterizeViewDependent(
          out, poses, uvPx[a], uvPx[b], uvPx[c], a, b, c, textureSize, blend);
    }

    return out;
  }

  void _rasterizeViewDependent(
    img.Image out,
    List<WeightedPose> poses,
    Vector2 uvA,
    Vector2 uvB,
    Vector2 uvC,
    int a,
    int b,
    int c,
    int size,
    bool blend,
  ) {
    final int minX = math.max(0, _floor3(uvA.x, uvB.x, uvC.x));
    final int maxX = math.min(size - 1, _ceil3(uvA.x, uvB.x, uvC.x));
    final int minY = math.max(0, _floor3(uvA.y, uvB.y, uvC.y));
    final int maxY = math.min(size - 1, _ceil3(uvA.y, uvB.y, uvC.y));
    if (minX > maxX || minY > maxY) {
      return;
    }

    // Per-pose vertex weights for this triangle (interpolated per texel below).
    final int n = poses.length;
    final List<double> wA = List<double>.filled(n, 0);
    final List<double> wB = List<double>.filled(n, 0);
    final List<double> wC = List<double>.filled(n, 0);
    for (int i = 0; i < n; i++) {
      final List<double> w = poses[i].weight;
      wA[i] = a < w.length ? w[a] : 0;
      wB[i] = b < w.length ? w[b] : 0;
      wC[i] = c < w.length ? w[c] : 0;
    }

    for (int py = minY; py <= maxY; py++) {
      for (int px = minX; px <= maxX; px++) {
        final Vector2 p = Vector2(px + 0.5, py + 0.5);
        final Vector3? bc = barycentric(p, uvA, uvB, uvC);
        if (bc == null || bc.x < 0 || bc.y < 0 || bc.z < 0) {
          continue;
        }

        _Rgb? colour;
        if (blend) {
          // Weighted average across all covering poses.
          double accW = 0;
          double accR = 0;
          double accG = 0;
          double accB = 0;
          for (int i = 0; i < n; i++) {
            final double w = bc.x * wA[i] + bc.y * wB[i] + bc.z * wC[i];
            if (w <= 0) {
              continue;
            }
            final _Rgb? s = _sampleFace(poses[i].pose, bc, a, b, c);
            if (s == null) {
              continue;
            }
            final List<double> g = poses[i].gain;
            accW += w;
            accR += s.r * g[0] * w;
            accG += s.g * g[1] * w;
            accB += s.b * g[2] * w;
          }
          if (accW > 0) {
            colour = _Rgb(
              (accR / accW).round().clamp(0, 255),
              (accG / accW).round().clamp(0, 255),
              (accB / accW).round().clamp(0, 255),
            );
          }
        } else {
          // Best-only: highest-weight pose that yields a sample (no mixing →
          // full sharpness). Ties/misses fall through to the next best.
          double bestW = 0;
          for (int i = 0; i < n; i++) {
            final double w = bc.x * wA[i] + bc.y * wB[i] + bc.z * wC[i];
            if (w <= bestW) {
              continue;
            }
            final _Rgb? s = _sampleFace(poses[i].pose, bc, a, b, c);
            if (s == null) {
              continue;
            }
            bestW = w;
            colour = _applyGain(s, poses[i].gain);
          }
        }

        if (colour != null) {
          out.setPixelRgba(px, py, colour.r, colour.g, colour.b, 255);
          continue;
        }

        // No pose covers this texel (all guarded off / grazing / off-image):
        // fall back to the first (frontal) pose so we don't leave a hole.
        final _Rgb? fallback = _sampleFace(poses.first.pose, bc, a, b, c);
        if (fallback != null) {
          out.setPixelRgba(px, py, fallback.r, fallback.g, fallback.b, 255);
        }
      }
    }
  }

  void _rasterizeTriangle(
    img.Image out,
    BakePose frontal,
    BakePose left,
    BakePose right,
    BakePose? up,
    List<double> downWeight,
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

    // Per-texel blend weight (result↔chin-up) for the lower/under-face region.
    final double da = _downWeight(a, downWeight);
    final double db = _downWeight(b, downWeight);
    final double dc = _downWeight(c, downWeight);

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

        // Pull the under-nose / lips / chin from the chin-up still (applied
        // after the side blend so the cheeks/jaw keep their side source).
        final double wd = bc.x * da + bc.y * db + bc.z * dc;
        if (up != null && wd > 0) {
          final _Rgb? upColour = _sampleFace(up, bc, a, b, c);
          if (upColour != null) {
            colour = _lerp(colour, upColour, wd);
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

  /// Samples [pose]'s still at vertex [i] (project the face-local vertex →
  /// bilinear). Null if outside the image / behind the camera.
  _Rgb? _sampleVertex(BakePose pose, int i) {
    if (i < 0 || i >= pose.vertices.length) {
      return null;
    }
    final Vector2? pixel = pose.projection.projectPixel(pose.vertices[i]);
    if (pixel == null) {
      return null;
    }
    return _sampleBilinear(pose.image, pixel.x, pixel.y);
  }

  /// Per-channel RGB gain that best matches [pose]'s colours to [reference]
  /// (frontal) over the vertices both poses see well — the overlap where their
  /// weights exceed [minWeight]. This removes AE/AWB/exposure seams when the two
  /// are stitched. Returns `[1,1,1]` (no correction) if the overlap is too small
  /// ([minSamples]) or degenerate. Gains are clamped to `[minGain, maxGain]`.
  List<double> poseGain({
    required BakePose reference,
    required BakePose pose,
    required List<double> refWeight,
    required List<double> poseWeight,
    double minWeight = 0.02,
    int minSamples = 50,
    double minGain = 0.5,
    double maxGain = 2.0,
  }) {
    double sr = 0, sg = 0, sb = 0; // reference sums
    double pr = 0, pg = 0, pb = 0; // pose sums
    int count = 0;
    final int n = math.min(refWeight.length, poseWeight.length);
    for (int i = 0; i < n; i++) {
      if (refWeight[i] <= minWeight || poseWeight[i] <= minWeight) {
        continue;
      }
      final _Rgb? rc = _sampleVertex(reference, i);
      final _Rgb? pc = _sampleVertex(pose, i);
      if (rc == null || pc == null) {
        continue;
      }
      sr += rc.r;
      sg += rc.g;
      sb += rc.b;
      pr += pc.r;
      pg += pc.g;
      pb += pc.b;
      count++;
    }
    if (count < minSamples || pr <= 0 || pg <= 0 || pb <= 0) {
      return const <double>[1, 1, 1];
    }
    return <double>[
      (sr / pr).clamp(minGain, maxGain),
      (sg / pg).clamp(minGain, maxGain),
      (sb / pb).clamp(minGain, maxGain),
    ];
  }

  /// Mean RGB of [pose] over the vertices it uses (weight > [minWeight]). Null if
  /// fewer than [minSamples] usable vertices. Used for the "neutral" white-
  /// balance mode (normalise every pose to a shared target instead of frontal).
  List<double>? poseMeanColor({
    required BakePose pose,
    required List<double> weight,
    double minWeight = 0.02,
    int minSamples = 50,
  }) {
    double sr = 0, sg = 0, sb = 0;
    int count = 0;
    for (int i = 0; i < weight.length; i++) {
      if (weight[i] <= minWeight) {
        continue;
      }
      final _Rgb? c = _sampleVertex(pose, i);
      if (c == null) {
        continue;
      }
      sr += c.r;
      sg += c.g;
      sb += c.b;
      count++;
    }
    if (count < minSamples) {
      return null;
    }
    return <double>[sr / count, sg / count, sb / count];
  }

  /// Per-channel gain mapping [mean] → [target], clamped to `[minGain, maxGain]`.
  /// Identity if either is degenerate.
  static List<double> gainToTarget(
    List<double> mean,
    List<double> target, {
    double minGain = 0.5,
    double maxGain = 2.0,
  }) {
    final List<double> g = <double>[1, 1, 1];
    for (int c = 0; c < 3; c++) {
      if (mean[c] > 0 && target[c] > 0) {
        g[c] = (target[c] / mean[c]).clamp(minGain, maxGain);
      }
    }
    return g;
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

  double _downWeight(int i, List<double> downWeight) =>
      (i >= 0 && i < downWeight.length) ? downWeight[i] : 0;

  _Rgb _applyGain(_Rgb s, List<double> g) => _Rgb(
        (s.r * g[0]).round().clamp(0, 255),
        (s.g * g[1]).round().clamp(0, 255),
        (s.b * g[2]).round().clamp(0, 255),
      );

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
