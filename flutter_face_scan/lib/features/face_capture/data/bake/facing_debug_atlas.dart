import 'package:image/image.dart' as img;

import '../../domain/v3/view_weights.dart';
import 'texture_baker.dart';

/// UV-atlas montage of clip `n·v` coverage. Does not change albedo bake.
///
/// 2×2 panels (same colour scale / same UVs):
///  * TL — clip classified: green = good, orange = poor, black = unseen
///  * TR — clip raw `n·v` as grayscale (`0` black → `1` white)
///  * BL — suggested fill: green = keep clip, red = left, blue = right,
///         yellow = chin-up, magenta = nobody sees it
///  * BR — best support `n·v` grayscale (max of L / R / chin-up)
abstract final class FacingDebugAtlas {
  static const List<int> rgbUnseen = <int>[20, 20, 24];
  static const List<int> rgbPoor = <int>[255, 140, 0];
  static const List<int> rgbGood = <int>[40, 200, 90];
  static const List<int> rgbNobody = <int>[255, 0, 255];

  static List<int> qualityRgb(FacingQuality q) {
    switch (q) {
      case FacingQuality.unseen:
        return rgbUnseen;
      case FacingQuality.poor:
        return rgbPoor;
      case FacingQuality.good:
        return rgbGood;
    }
  }

  static List<int> fillRgb(FacingFillHint h) {
    switch (h) {
      case FacingFillHint.clip:
        return rgbGood;
      case FacingFillHint.left:
        return TextureBaker.debugLeftRgb;
      case FacingFillHint.right:
        return TextureBaker.debugRightRgb;
      case FacingFillHint.chinUp:
        return TextureBaker.debugChinUpRgb;
      case FacingFillHint.none:
        return rgbNobody;
    }
  }

  static List<int> heatRgb(double nDotV) {
    final int v = (nDotV.clamp(0.0, 1.0) * 255).round();
    return <int>[v, v, v];
  }

  static img.Image buildMontage({
    required TextureBaker baker,
    required List<double> uvs,
    required List<int> triangles,
    required int textureSize,
    required List<double> frontalNv,
    List<double>? leftNv,
    List<double>? rightNv,
    List<double>? chinNv,
  }) {
    final int n = frontalNv.length;
    final List<int> classified = List<int>.filled(n * 3, 0);
    final List<int> heat = List<int>.filled(n * 3, 0);
    final List<int> fill = List<int>.filled(n * 3, 0);
    final List<int> supportHeat = List<int>.filled(n * 3, 0);
    for (int i = 0; i < n; i++) {
      final double f = frontalNv[i];
      final double l = (leftNv != null && i < leftNv.length) ? leftNv[i] : 0;
      final double r = (rightNv != null && i < rightNv.length) ? rightNv[i] : 0;
      final double c = (chinNv != null && i < chinNv.length) ? chinNv[i] : 0;
      putRgb(classified, i, qualityRgb(facingQuality(f)));
      putRgb(heat, i, heatRgb(f));
      putRgb(fill, i, fillRgb(facingFillHint(
        frontal: f,
        left: l,
        right: r,
        chinUp: c,
      )));
      final double supportMax =
          l > r ? (l > c ? l : c) : (r > c ? r : c);
      putRgb(supportHeat, i, heatRgb(supportMax));
    }

    final int half = textureSize > 1 ? textureSize ~/ 2 : 1;
    img.Image panel(List<int> rgb) => img.copyResize(
          baker.bakeVertexRgb(
            rgb: rgb,
            uvs: uvs,
            triangles: triangles,
            textureSize: textureSize,
          ),
          width: half,
          height: half,
        );

    final img.Image out = img.Image(
      width: textureSize,
      height: textureSize,
      numChannels: 4,
    );
    img.fill(out, color: img.ColorRgba8(8, 8, 10, 255));
    img.compositeImage(out, panel(classified), dstX: 0, dstY: 0);
    img.compositeImage(out, panel(heat), dstX: half, dstY: 0);
    img.compositeImage(out, panel(fill), dstX: 0, dstY: half);
    img.compositeImage(out, panel(supportHeat), dstX: half, dstY: half);
    return out;
  }

  /// Full-atlas map: each vertex is the pose with the highest raw `n·v`
  /// (green=clip, red=left, blue=right, yellow=chin-up, magenta=nobody).
  static img.Image buildBestView({
    required TextureBaker baker,
    required List<double> uvs,
    required List<int> triangles,
    required int textureSize,
    required List<double> frontalNv,
    List<double>? leftNv,
    List<double>? rightNv,
    List<double>? chinNv,
  }) {
    final int n = frontalNv.length;
    final List<int> rgb = List<int>.filled(n * 3, 0);
    for (int i = 0; i < n; i++) {
      putRgb(
        rgb,
        i,
        fillRgb(_bestAt(i, frontalNv, leftNv, rightNv, chinNv)),
      );
    }
    return baker.bakeVertexRgb(
      rgb: rgb,
      uvs: uvs,
      triangles: triangles,
      textureSize: textureSize,
    );
  }

  static FacingFillHint _bestAt(
    int i,
    List<double> frontalNv,
    List<double>? leftNv,
    List<double>? rightNv,
    List<double>? chinNv,
  ) =>
      facingBestView(
        frontal: frontalNv[i],
        left: (leftNv != null && i < leftNv.length) ? leftNv[i] : 0,
        right: (rightNv != null && i < rightNv.length) ? rightNv[i] : 0,
        chinUp: (chinNv != null && i < chinNv.length) ? chinNv[i] : 0,
      );

  static Map<String, Object?> legendJson({
    required List<double> frontalNv,
    List<double>? leftNv,
    List<double>? rightNv,
    List<double>? chinNv,
    required bool leftLoaded,
    required bool rightLoaded,
    required bool chinLoaded,
  }) {
    int good = 0, poor = 0, unseen = 0;
    int needLeft = 0, needRight = 0, needChin = 0, nobody = 0, keepClip = 0;
    int bestClip = 0,
        bestLeft = 0,
        bestRight = 0,
        bestChin = 0,
        bestNobody = 0;
    final int n = frontalNv.length;
    for (int i = 0; i < n; i++) {
      final double f = frontalNv[i];
      switch (facingQuality(f)) {
        case FacingQuality.good:
          good++;
        case FacingQuality.poor:
          poor++;
        case FacingQuality.unseen:
          unseen++;
      }
      final double l = (leftNv != null && i < leftNv.length) ? leftNv[i] : 0;
      final double r = (rightNv != null && i < rightNv.length) ? rightNv[i] : 0;
      final double c = (chinNv != null && i < chinNv.length) ? chinNv[i] : 0;
      final FacingFillHint h = facingFillHint(
        frontal: f,
        left: l,
        right: r,
        chinUp: c,
      );
      switch (h) {
        case FacingFillHint.clip:
          keepClip++;
        case FacingFillHint.left:
          needLeft++;
        case FacingFillHint.right:
          needRight++;
        case FacingFillHint.chinUp:
          needChin++;
        case FacingFillHint.none:
          nobody++;
      }
      switch (facingBestView(frontal: f, left: l, right: r, chinUp: c)) {
        case FacingFillHint.clip:
          bestClip++;
        case FacingFillHint.left:
          bestLeft++;
        case FacingFillHint.right:
          bestRight++;
        case FacingFillHint.chinUp:
          bestChin++;
        case FacingFillHint.none:
          bestNobody++;
      }
    }
    return <String, Object?>{
      'nDotV':
          'cos(angle between surface normal and camera). 1=head-on, 0=90° grazing, <0=backface.',
      'frontal':
          'Max n·v over clip frames (best the video ever saw each vertex).',
      'bands': <String, Object?>{
        'good': <String, Object?>{
          'min': kFacingGoodMin,
          'color': '#28c85a',
          'angleFromHeadOnDeg': 60,
          'meaning':
              'Clip sees this head-on enough. L/R / chin-up should stay out.',
        },
        'poor': <String, Object?>{
          'min': kDefaultMinFacing,
          'max': kFacingGoodMin,
          'color': '#ff8c00',
          'angleFromHeadOnDeg': <int>[60, 78],
          'meaning':
              'Clip still sees it, but grazing (~60–78°). Stretched if used. Candidate for L/R or chin-up.',
        },
        'unseen': <String, Object?>{
          'max': kDefaultMinFacing,
          'color': '#141418',
          'angleFromHeadOnDeg': 78,
          'meaning':
              'Clip is blind (n·v < kDefaultMinFacing). Must come from L/R / chin-up or stay empty.',
        },
      },
      'thresholdsWhy': <String, String>{
        '0.20':
            'kDefaultMinFacing — bake discards samples below this as grazing stretch (cos 78°).',
        '0.50':
            'kFacingGoodMin — clip-only cutoff (cos 60°). Below this the frontal JPEG smears (grey stripe).',
      },
      'panels': <String, String>{
        'tl': 'clip classified (green=good, orange=poor, black=unseen)',
        'tr': 'clip raw n·v grayscale (0 black → 1 white)',
        'bl':
            'suggested fill: green=clip, red=left, blue=right, yellow=chin-up, magenta=nobody',
        'br': 'best support n·v grayscale (max of L/R/chin-up)',
      },
      'bestViewPng': 'debug_nv_best.png',
      'bestView':
          'Argmax n·v per vertex. Green=clip, red=left, blue=right, yellow=chin-up, magenta=nobody (all < 0.20). Unlike suggested-fill, clip does not win just for being ≥ 0.50.',
      'bestViewColors': <String, String>{
        'clip': '#28c85a',
        'left': '#eb3746',
        'right': '#3769ff',
        'chinUp': '#ffc828',
        'nobody': '#ff00ff',
      },
      'supportLoaded': <String, bool>{
        'left40': leftLoaded,
        'right40': rightLoaded,
        'up': chinLoaded,
      },
      'stats': <String, int>{
        'vertexCount': n,
        'frontalGood': good,
        'frontalPoor': poor,
        'frontalUnseen': unseen,
        'keepClip': keepClip,
        'needLeft': needLeft,
        'needRight': needRight,
        'needChinUp': needChin,
        'nobody': nobody,
        'bestClip': bestClip,
        'bestLeft': bestLeft,
        'bestRight': bestRight,
        'bestChinUp': bestChin,
        'bestNobody': bestNobody,
      },
    };
  }

  static void putRgb(List<int> rgb, int vertex, List<int> c) {
    final int i = vertex * 3;
    rgb[i] = c[0];
    rgb[i + 1] = c[1];
    rgb[i + 2] = c[2];
  }
}
