import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart';

import '../../domain/constants/face_regions.g.dart';
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

/// A [BakePose] paired with its per-vertex view-dependent weight (guarded
/// `n·v`), index-aligned with [BakePose.vertices]. See
/// `domain/v3/view_weights.dart`.
final class WeightedPose {
  const WeightedPose({
    required this.pose,
    required this.weight,
    this.gain = const <double>[1, 1, 1],
    this.debugRgb,
  });

  final BakePose pose;

  /// Per-vertex weight (0 = don't use this pose here), length ==
  /// `pose.vertices.length`.
  final List<double> weight;

  /// Per-channel RGB multiplier applied to this pose's samples to match the
  /// reference (frontal) exposure/white-balance. `[1,1,1]` = no correction.
  /// See [TextureBaker.poseGain].
  final List<double> gain;

  /// Source-debug tint colour. With [TextureBaker.bakeViewDependent] `debugTint`
  /// > 0, photo samples stay visible and lerp toward this RGB (filter look).
  /// With `debugTint` == 0 and this set, paints solid debug colour (legacy).
  final List<int>? debugRgb;
}

/// Bakes the face texture (ARKit UV atlas) from the three poses: per texel →
/// covering triangle → face-local point → project into the photos → blend
/// frontal↔side by [FaceRegions.sideWeight]. Output PNG is top-left origin. Pure.
final class TextureBaker {
  const TextureBaker();

  /// Clip / frontal source in [debugRgb] maps.
  static const List<int> debugFrontalRgb = <int>[40, 230, 90];

  /// Anatomical left cheek (right40 still).
  static const List<int> debugLeftRgb = <int>[235, 55, 70];

  /// Anatomical right cheek (left40 still).
  static const List<int> debugRightRgb = <int>[55, 105, 255];

  /// Chin-up support still (under-chin / nostrils).
  static const List<int> debugChinUpRgb = <int>[255, 200, 40];

  static List<int> debugRgbForIndex(int i) {
    switch (i) {
      case 0:
        return debugFrontalRgb;
      case 1:
        return debugLeftRgb;
      case 2:
        return debugRightRgb;
      case 3:
        return debugChinUpRgb;
      default:
        return const <int>[255, 0, 255];
    }
  }

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
  ///
  /// [solidFillFromFlatIndex]: flat triangle-list offset at which aperture-fill
  /// tris begin (e.g. mouth caps). Those tris get a flat dark fill — no photo
  /// projection into the cavity (avoids patchy grey / wrong lip colours).
  ///
  /// [screenSpaceFrontalVertices]: triangles whose three verts are in this set
  /// (eye hole caps) sample the **first** pose in 2D photo space — lerp the
  /// projected rim pixels — instead of 3D-interpolate-then-project. That copies
  /// the inner eye from the frontal JPEG as seen between the lids.
  /// [frontalOnlyVertices]: any triangle that touches this set (eyelids) is
  /// rasterized from the first pose only — side stills cannot bleed an iris
  /// through barycentric mix at the lid/cheek boundary.
  ///
  /// [skipStitchLerpVertices]: triangles that touch this set keep winner-only
  /// colour (no clip↔support RGB lerp). Mouth / brows — mixing smile with a
  /// rest still warps the feature.
  ///
  /// [debugTint]: 0 = normal (or solid [WeightedPose.debugRgb] if set).
  /// (0,1] = sample the photo, then lerp toward each pose's [debugRgb]
  /// (skin still readable; strong colour filter for source maps).
  img.Image bakeViewDependent({
    required List<WeightedPose> poses,
    required List<double> uvs,
    required List<int> triangles,
    int textureSize = 2048,
    bool blend = true,
    int? solidFillFromFlatIndex,
    List<int> solidFillRgb = const <int>[12, 8, 8],
    Set<int>? screenSpaceFrontalVertices,
    Set<int>? frontalOnlyVertices,
    Set<int>? skipStitchLerpVertices,
    double debugTint = 0,
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

    final int fillR =
        solidFillRgb.isNotEmpty ? solidFillRgb[0].clamp(0, 255).toInt() : 12;
    final int fillG =
        solidFillRgb.length > 1 ? solidFillRgb[1].clamp(0, 255).toInt() : 8;
    final int fillB =
        solidFillRgb.length > 2 ? solidFillRgb[2].clamp(0, 255).toInt() : 8;

    for (int t = 0; t + 2 < triangles.length; t += 3) {
      final int a = triangles[t];
      final int b = triangles[t + 1];
      final int c = triangles[t + 2];
      if (a >= uvPx.length || b >= uvPx.length || c >= uvPx.length) {
        continue;
      }
      if (solidFillFromFlatIndex != null && t >= solidFillFromFlatIndex) {
        _rasterizeSolid(
          out,
          uvPx[a],
          uvPx[b],
          uvPx[c],
          textureSize,
          fillR,
          fillG,
          fillB,
        );
        continue;
      }
      if (screenSpaceFrontalVertices != null &&
          screenSpaceFrontalVertices.contains(a) &&
          screenSpaceFrontalVertices.contains(b) &&
          screenSpaceFrontalVertices.contains(c)) {
        _rasterizeScreenSpaceFrontal(
          out,
          poses.first.pose,
          uvPx[a],
          uvPx[b],
          uvPx[c],
          a,
          b,
          c,
          textureSize,
          debugRgb: poses.first.debugRgb,
          debugTint: debugTint,
        );
        continue;
      }
      if (frontalOnlyVertices != null &&
          (frontalOnlyVertices.contains(a) ||
              frontalOnlyVertices.contains(b) ||
              frontalOnlyVertices.contains(c))) {
        _rasterizeViewDependent(
          out,
          <WeightedPose>[poses.first],
          uvPx[a],
          uvPx[b],
          uvPx[c],
          a,
          b,
          c,
          textureSize,
          blend,
          debugTint,
        );
        continue;
      }
      final bool allowStitchLerp = skipStitchLerpVertices == null ||
          !(skipStitchLerpVertices.contains(a) ||
              skipStitchLerpVertices.contains(b) ||
              skipStitchLerpVertices.contains(c));
      _rasterizeViewDependent(
        out,
        poses,
        uvPx[a],
        uvPx[b],
        uvPx[c],
        a,
        b,
        c,
        textureSize,
        blend,
        debugTint,
        allowStitchLerp,
      );
    }

    return out;
  }

  /// Rasterize per-vertex RGB into the UV atlas (barycentric lerp). [rgb] is
  /// flat `r,g,b` per vertex, length ≥ vertexCount·3. Uncovered texels stay
  /// transparent. Pure.
  img.Image bakeVertexRgb({
    required List<int> rgb,
    required List<double> uvs,
    required List<int> triangles,
    int textureSize = 1024,
  }) {
    final img.Image out = img.Image(
      width: textureSize,
      height: textureSize,
      numChannels: 4,
    );
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
      _rasterizeVertexRgb(
        out,
        rgb,
        uvPx[a],
        uvPx[b],
        uvPx[c],
        a,
        b,
        c,
        textureSize,
      );
    }
    return out;
  }

  void _rasterizeVertexRgb(
    img.Image out,
    List<int> rgb,
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
    final int ai = a * 3;
    final int bi = b * 3;
    final int ci = c * 3;
    if (ai + 2 >= rgb.length || bi + 2 >= rgb.length || ci + 2 >= rgb.length) {
      return;
    }
    for (int py = minY; py <= maxY; py++) {
      for (int px = minX; px <= maxX; px++) {
        final Vector2 p = Vector2(px + 0.5, py + 0.5);
        final Vector3? bc = barycentric(p, uvA, uvB, uvC);
        if (bc == null || bc.x < 0 || bc.y < 0 || bc.z < 0) {
          continue;
        }
        final int r = (bc.x * rgb[ai] + bc.y * rgb[bi] + bc.z * rgb[ci])
            .round()
            .clamp(0, 255);
        final int g = (bc.x * rgb[ai + 1] + bc.y * rgb[bi + 1] + bc.z * rgb[ci + 1])
            .round()
            .clamp(0, 255);
        final int bch =
            (bc.x * rgb[ai + 2] + bc.y * rgb[bi + 2] + bc.z * rgb[ci + 2])
                .round()
                .clamp(0, 255);
        out.setPixelRgba(px, py, r, g, bch, 255);
      }
    }
  }

  /// Eye-cap tris: UV raster like the rest of the atlas, photo lookup in 2D.
  /// `pixel = bc · project(rim)` copies whatever sits between the lids in the
  /// frontal JPEG, instead of hitting a receded iris via a flat 3D disc.
  void _rasterizeScreenSpaceFrontal(
    img.Image out,
    BakePose frontal,
    Vector2 uvA,
    Vector2 uvB,
    Vector2 uvC,
    int a,
    int b,
    int c,
    int size, {
    List<int>? debugRgb,
    double debugTint = 0,
  }) {
    if (a >= frontal.vertices.length ||
        b >= frontal.vertices.length ||
        c >= frontal.vertices.length) {
      return;
    }
    final Vector2? pA = frontal.projection.projectPixel(frontal.vertices[a]);
    final Vector2? pB = frontal.projection.projectPixel(frontal.vertices[b]);
    final Vector2? pC = frontal.projection.projectPixel(frontal.vertices[c]);
    if (pA == null || pB == null || pC == null) {
      return;
    }
    final _Rgb? debug = _rgbFromDebug(debugRgb);
    final double tint = debugTint.clamp(0.0, 1.0);
    if (debug != null && tint <= 0) {
      _rasterizeScreenSpaceLoop(out, uvA, uvB, uvC, size, (_) => debug);
      return;
    }
    _rasterizeScreenSpaceLoop(
      out,
      uvA,
      uvB,
      uvC,
      size,
      (Vector3 bc) {
        final double sx = bc.x * pA.x + bc.y * pB.x + bc.z * pC.x;
        final double sy = bc.x * pA.y + bc.y * pB.y + bc.z * pC.y;
        final _Rgb? photo = _sampleBilinear(frontal.image, sx, sy);
        if (photo == null) {
          return null;
        }
        if (debug == null || tint <= 0) {
          return photo;
        }
        return _lerp(photo, debug, tint);
      },
    );
  }

  void _rasterizeScreenSpaceLoop(
    img.Image out,
    Vector2 uvA,
    Vector2 uvB,
    Vector2 uvC,
    int size,
    _Rgb? Function(Vector3 bc) sample,
  ) {
    final int minX = math.max(0, _floor3(uvA.x, uvB.x, uvC.x));
    final int maxX = math.min(size - 1, _ceil3(uvA.x, uvB.x, uvC.x));
    final int minY = math.max(0, _floor3(uvA.y, uvB.y, uvC.y));
    final int maxY = math.min(size - 1, _ceil3(uvA.y, uvB.y, uvC.y));
    if (minX > maxX || minY > maxY) {
      return;
    }
    for (int py = minY; py <= maxY; py++) {
      for (int px = minX; px <= maxX; px++) {
        final Vector2 p = Vector2(px + 0.5, py + 0.5);
        final Vector3? bc = barycentric(p, uvA, uvB, uvC);
        if (bc == null || bc.x < 0 || bc.y < 0 || bc.z < 0) {
          continue;
        }
        final _Rgb? colour = sample(bc);
        if (colour != null) {
          out.setPixelRgba(px, py, colour.r, colour.g, colour.b, 255);
        }
      }
    }
  }

  void _rasterizeSolid(
    img.Image out,
    Vector2 uvA,
    Vector2 uvB,
    Vector2 uvC,
    int size,
    int r,
    int g,
    int b,
  ) {
    final int minX = math.max(0, _floor3(uvA.x, uvB.x, uvC.x));
    final int maxX = math.min(size - 1, _ceil3(uvA.x, uvB.x, uvC.x));
    final int minY = math.max(0, _floor3(uvA.y, uvB.y, uvC.y));
    final int maxY = math.min(size - 1, _ceil3(uvA.y, uvB.y, uvC.y));
    if (minX > maxX || minY > maxY) {
      return;
    }
    for (int py = minY; py <= maxY; py++) {
      for (int px = minX; px <= maxX; px++) {
        final Vector2 p = Vector2(px + 0.5, py + 0.5);
        final Vector3? bc = barycentric(p, uvA, uvB, uvC);
        if (bc == null || bc.x < 0 || bc.y < 0 || bc.z < 0) {
          continue;
        }
        out.setPixelRgba(px, py, r, g, b, 255);
      }
    }
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
    bool blend, [
    double debugTint = 0,
    bool allowStitchLerp = true,
  ]) {
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
            final _Rgb? s = _poseSample(poses[i], bc, a, b, c, debugTint);
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
          // Best-only interior. Only triangles whose verts disagree on the
          // winner (the clip↔support stitch) lerp RGB — never the L/R fill.
          int argMax(List<double> wv) {
            int b = 0;
            for (int i = 1; i < wv.length; i++) {
              if (wv[i] > wv[b]) {
                b = i;
              }
            }
            return b;
          }

          final bool stitchTri =
              argMax(wA) != argMax(wB) || argMax(wB) != argMax(wC);

          _Rgb? bestColour;
          _Rgb? secondColour;
          double bestW = 0;
          double secondW = 0;
          for (int i = 0; i < n; i++) {
            final double w = bc.x * wA[i] + bc.y * wB[i] + bc.z * wC[i];
            if (w <= 0) {
              continue;
            }
            final _Rgb? s = _poseSample(poses[i], bc, a, b, c, debugTint);
            if (s == null) {
              continue;
            }
            final _Rgb gained = _applyGain(s, poses[i].gain);
            if (w > bestW) {
              secondW = bestW;
              secondColour = bestColour;
              bestW = w;
              bestColour = gained;
            } else if (w > secondW) {
              secondW = w;
              secondColour = gained;
            }
          }
          if (allowStitchLerp &&
              stitchTri &&
              bestColour != null &&
              secondColour != null &&
              secondW > 0 &&
              bestW > 0) {
            final double t = secondW / (bestW + secondW);
            colour = _lerp(bestColour, secondColour, t * 0.55);
          } else {
            colour = bestColour;
          }
        }

        if (colour != null) {
          out.setPixelRgba(px, py, colour.r, colour.g, colour.b, 255);
          continue;
        }

        // No pose covers this texel (all guarded off / grazing / off-image).
        // Only fall back to frontal when it still has meaningful facing —
        // otherwise we smear a stretched skin tone into occluded sides.
        final double frontW = n > 0
            ? (bc.x * wA[0] + bc.y * wB[0] + bc.z * wC[0])
            : 0;
        if (frontW > 0.05) {
          final _Rgb? fallback =
              _poseSample(poses.first, bc, a, b, c, debugTint);
          if (fallback != null) {
            out.setPixelRgba(px, py, fallback.r, fallback.g, fallback.b, 255);
          }
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

  _Rgb? _poseSample(
    WeightedPose pose,
    Vector3 bc,
    int a,
    int b,
    int c, [
    double debugTint = 0,
  ]) {
    final _Rgb? debug = _rgbFromDebug(pose.debugRgb);
    final double tint = debugTint.clamp(0.0, 1.0);
    if (debug != null && tint <= 0) {
      return debug;
    }
    final _Rgb? photo = _sampleFace(pose.pose, bc, a, b, c);
    if (photo == null) {
      return debug != null && tint > 0 ? debug : null;
    }
    if (debug == null || tint <= 0) {
      return photo;
    }
    return _lerp(photo, debug, tint);
  }

  static _Rgb? _rgbFromDebug(List<int>? rgb) {
    if (rgb == null || rgb.length < 3) {
      return null;
    }
    return _Rgb(
      rgb[0].clamp(0, 255).toInt(),
      rgb[1].clamp(0, 255).toInt(),
      rgb[2].clamp(0, 255).toInt(),
    );
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
  ///
  /// Samples are weighted by `min(ref, pose)` so the actual stitch band drives
  /// the gain (not equal-weight cheek blobs far from the seam).
  ///
  /// [luminanceOnly]: one Rec.709 scale on R=G=B — kills brightness blotches
  /// without per-channel colour shifts (better for side-lit nose wings).
  List<double> poseGain({
    required BakePose reference,
    required BakePose pose,
    required List<double> refWeight,
    required List<double> poseWeight,
    double minWeight = 0.02,
    int minSamples = 50,
    double minGain = 0.5,
    double maxGain = 2.0,
    bool luminanceOnly = false,
  }) {
    double sr = 0, sg = 0, sb = 0; // reference sums (weight-scaled)
    double pr = 0, pg = 0, pb = 0; // pose sums
    int count = 0;
    final int n = math.min(refWeight.length, poseWeight.length);
    for (int i = 0; i < n; i++) {
      final double w = math.min(refWeight[i], poseWeight[i]);
      if (w <= minWeight) {
        continue;
      }
      final _Rgb? rc = _sampleVertex(reference, i);
      final _Rgb? pc = _sampleVertex(pose, i);
      if (rc == null || pc == null) {
        continue;
      }
      sr += rc.r * w;
      sg += rc.g * w;
      sb += rc.b * w;
      pr += pc.r * w;
      pg += pc.g * w;
      pb += pc.b * w;
      count++;
    }
    if (count < minSamples || pr <= 0 || pg <= 0 || pb <= 0) {
      return const <double>[1, 1, 1];
    }
    if (luminanceOnly) {
      // Rec.709 luma on weighted channel sums (same scale cancels).
      final double yRef = 0.2126 * sr + 0.7152 * sg + 0.0722 * sb;
      final double yPose = 0.2126 * pr + 0.7152 * pg + 0.0722 * pb;
      if (yPose <= 0 || yRef <= 0) {
        return const <double>[1, 1, 1];
      }
      final double g = (yRef / yPose).clamp(minGain, maxGain);
      return <double>[g, g, g];
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
