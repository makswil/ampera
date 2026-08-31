import 'package:flutter_face_scan/features/face_capture/data/bake/motion_debug_atlas.dart';
import 'package:flutter_face_scan/features/face_capture/data/bake/texture_baker.dart';
import 'package:flutter_face_scan/features/face_capture/domain/v3/view_weights.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('legendJson counts still / moving / conflict', () {
    final Map<String, Object?> json = MotionDebugAtlas.legendJson(
      displacementM: <double>[0.001, 0.005, 0.012, 0.015],
      bestView: <FacingFillHint>[
        FacingFillHint.left,
        FacingFillHint.clip,
        FacingFillHint.right,
        FacingFillHint.clip,
      ],
      restSource: 'test',
    );
    final Map<String, Object?> stats = json['stats']! as Map<String, Object?>;
    expect(stats['still'], 1);
    expect(stats['slight'], 1);
    expect(stats['moving'], 2);
    expect(stats['conflictMovingButSideBest'], 1); // 12 mm + right
  });

  test('gateRgb marks moving+side as magenta', () {
    expect(
      MotionDebugAtlas.gateRgb(0.012, FacingFillHint.left),
      MotionDebugAtlas.rgbConflict,
    );
    expect(
      MotionDebugAtlas.gateRgb(0.001, FacingFillHint.left),
      TextureBaker.debugLeftRgb,
    );
  });

  test('buildMontage writes a non-empty atlas', () {
    final img.Image out = MotionDebugAtlas.buildMontage(
      baker: const TextureBaker(),
      uvs: <double>[0, 0, 1, 0, 0, 1],
      triangles: <int>[0, 1, 2],
      textureSize: 8,
      displacementM: <double>[0.001, 0.01, 0.0],
    );
    expect(out.width, 8);
    var covered = false;
    for (int y = 0; y < out.height; y++) {
      for (int x = 0; x < out.width; x++) {
        if (out.getPixel(x, y).a > 0) {
          covered = true;
        }
      }
    }
    expect(covered, isTrue);
  });
}
