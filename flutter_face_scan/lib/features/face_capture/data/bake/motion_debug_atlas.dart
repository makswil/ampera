import 'package:image/image.dart' as img;

import '../../domain/v3/vertex_motion.dart';
import '../../domain/v3/view_weights.dart';
import 'facing_debug_atlas.dart';
import 'texture_baker.dart';

/// UV-atlas montage of expression vertex travel vs a neutral rest mesh.
///
/// 2×2:
///  * TL — classified: green=still, orange=slight, red=moving
///  * TR — displacement heatmap (black=0, white=[kMotionHeatScale] 20 mm)
///  * BL — gate vs best-view: support colour where still; red=moving;
///         magenta=moving but best-view wanted L/R/chin (smear risk)
///  * BR — still verts only, best-view colour (black = moving, hidden)
abstract final class MotionDebugAtlas {
  static const List<int> rgbStill = <int>[40, 200, 90];
  static const List<int> rgbSlight = <int>[255, 140, 0];
  static const List<int> rgbMoving = <int>[220, 40, 40];
  static const List<int> rgbConflict = <int>[255, 0, 255];
  static const List<int> rgbHidden = <int>[20, 20, 24];

  static List<int> qualityRgb(MotionQuality q) {
    switch (q) {
      case MotionQuality.still:
        return rgbStill;
      case MotionQuality.slight:
        return rgbSlight;
      case MotionQuality.moving:
        return rgbMoving;
    }
  }

  static List<int> heatRgb(double meters) {
    final int v = ((meters / kMotionHeatScale).clamp(0.0, 1.0) * 255).round();
    return <int>[v, v, v];
  }

  /// Magenta where motion forbids a side still that `n·v`-best would pick.
  static List<int> gateRgb(double meters, FacingFillHint best) {
    final MotionQuality q = motionQuality(meters);
    if (q == MotionQuality.moving) {
      if (best == FacingFillHint.left ||
          best == FacingFillHint.right ||
          best == FacingFillHint.chinUp) {
        return rgbConflict;
      }
      return rgbMoving;
    }
    if (q == MotionQuality.slight) {
      return rgbSlight;
    }
    return FacingDebugAtlas.fillRgb(best);
  }

  static img.Image buildMontage({
    required TextureBaker baker,
    required List<double> uvs,
    required List<int> triangles,
    required int textureSize,
    required List<double> displacementM,
    List<FacingFillHint>? bestView,
  }) {
    final int n = displacementM.length;
    final List<int> classified = List<int>.filled(n * 3, 0);
    final List<int> heat = List<int>.filled(n * 3, 0);
    final List<int> gate = List<int>.filled(n * 3, 0);
    final List<int> stillBest = List<int>.filled(n * 3, 0);
    for (int i = 0; i < n; i++) {
      final double d = displacementM[i];
      final FacingFillHint best = (bestView != null && i < bestView.length)
          ? bestView[i]
          : FacingFillHint.none;
      FacingDebugAtlas.putRgb(classified, i, qualityRgb(motionQuality(d)));
      FacingDebugAtlas.putRgb(heat, i, heatRgb(d));
      FacingDebugAtlas.putRgb(gate, i, gateRgb(d, best));
      final List<int> stillRgb = motionQuality(d) == MotionQuality.still
          ? FacingDebugAtlas.fillRgb(best)
          : rgbHidden;
      FacingDebugAtlas.putRgb(stillBest, i, stillRgb);
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
    img.compositeImage(out, panel(gate), dstX: 0, dstY: half);
    img.compositeImage(out, panel(stillBest), dstX: half, dstY: half);
    return out;
  }

  static Map<String, Object?> legendJson({
    required List<double> displacementM,
    List<FacingFillHint>? bestView,
    required String restSource,
  }) {
    int still = 0, slight = 0, moving = 0, conflict = 0;
    double maxM = 0;
    final int n = displacementM.length;
    for (int i = 0; i < n; i++) {
      final double d = displacementM[i];
      if (d > maxM) {
        maxM = d;
      }
      switch (motionQuality(d)) {
        case MotionQuality.still:
          still++;
        case MotionQuality.slight:
          slight++;
        case MotionQuality.moving:
          moving++;
      }
      final FacingFillHint best = (bestView != null && i < bestView.length)
          ? bestView[i]
          : FacingFillHint.none;
      if (motionQuality(d) == MotionQuality.moving &&
          (best == FacingFillHint.left ||
              best == FacingFillHint.right ||
              best == FacingFillHint.chinUp)) {
        conflict++;
      }
    }
    return <String, Object?>{
      'displacement':
          'Max Euclidean travel of each vertex vs rest, over all clip frames. Metres, face-local.',
      'rest': restSource,
      'bands': <String, Object?>{
        'still': <String, Object?>{
          'maxMeters': kMotionStillMax,
          'maxMm': 2,
          'color': '#28c85a',
          'meaning': 'Rigid enough that a neutral L/R / chin-up still may paint.',
        },
        'slight': <String, Object?>{
          'minMeters': kMotionStillMax,
          'maxMeters': kMotionMovingMin,
          'mm': <int>[2, 8],
          'color': '#ff8c00',
          'meaning': 'Soft zone — do not fully trust a support still.',
        },
        'moving': <String, Object?>{
          'minMeters': kMotionMovingMin,
          'minMm': 8,
          'color': '#dc2828',
          'meaning': 'Expression-driven. Clip JPEG only — no L/R mix.',
        },
      },
      'panels': <String, String>{
        'tl': 'classified (green=still, orange=slight, red=moving)',
        'tr': 'heatmap 0–20 mm (black→white)',
        'bl':
            'gate: support colour if still; red=moving; magenta=moving but n·v-best wanted a side still (smear risk)',
        'br': 'still verts only, n·v-best colour (moving hidden black)',
      },
      'stats': <String, Object?>{
        'vertexCount': n,
        'still': still,
        'slight': slight,
        'moving': moving,
        'conflictMovingButSideBest': conflict,
        'maxMeters': maxM,
        'maxMm': maxM * 1000,
      },
    };
  }
}
