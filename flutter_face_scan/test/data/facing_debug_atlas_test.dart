import 'package:flutter_face_scan/features/face_capture/data/bake/facing_debug_atlas.dart';
import 'package:flutter_face_scan/features/face_capture/data/bake/texture_baker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('legendJson counts good / poor / unseen and fill hints', () {
    final Map<String, Object?> json = FacingDebugAtlas.legendJson(
      frontalNv: <double>[1.0, 0.3, 0.05, 0.1],
      leftNv: <double>[0.1, 0.1, 0.8, 0.0],
      rightNv: <double>[0.1, 0.9, 0.1, 0.0],
      chinNv: <double>[0.1, 0.1, 0.1, 0.05],
      leftLoaded: true,
      rightLoaded: true,
      chinLoaded: true,
    );
    final Map<String, int> stats = json['stats']! as Map<String, int>;
    expect(stats['frontalGood'], 1);
    expect(stats['frontalPoor'], 1);
    expect(stats['frontalUnseen'], 2);
    expect(stats['keepClip'], 1);
    expect(stats['needRight'], 1); // 0.3 clip + 0.9 right
    expect(stats['needLeft'], 1); // 0.05 clip + 0.8 left
    expect(stats['nobody'], 1);
    expect(stats['bestClip'], 1);
    expect(stats['bestRight'], 1);
    expect(stats['bestLeft'], 1);
    expect(stats['bestNobody'], 1);
  });

  test('buildMontage writes a non-empty atlas', () {
    final img.Image out = FacingDebugAtlas.buildMontage(
      baker: const TextureBaker(),
      uvs: <double>[0, 0, 1, 0, 0, 1],
      triangles: <int>[0, 1, 2],
      textureSize: 8,
      frontalNv: <double>[1, 0.3, 0],
    );
    expect(out.width, 8);
    expect(out.height, 8);
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

  test('buildBestView paints the argmax pose colour', () {
    final img.Image out = FacingDebugAtlas.buildBestView(
      baker: const TextureBaker(),
      uvs: <double>[0, 0, 1, 0, 0, 1],
      triangles: <int>[0, 1, 2],
      textureSize: 8,
      frontalNv: <double>[0.3, 0.3, 0.3],
      leftNv: <double>[0.9, 0.9, 0.9],
    );
    ({int r, int g, int b})? covered;
    for (int y = 0; y < out.height; y++) {
      for (int x = 0; x < out.width; x++) {
        final img.Pixel p = out.getPixel(x, y);
        if (p.a > 0) {
          covered = (r: p.r.toInt(), g: p.g.toInt(), b: p.b.toInt());
          break;
        }
      }
      if (covered != null) {
        break;
      }
    }
    expect(covered, isNotNull);
    expect(covered!.r, TextureBaker.debugLeftRgb[0]);
    expect(covered.g, TextureBaker.debugLeftRgb[1]);
    expect(covered.b, TextureBaker.debugLeftRgb[2]);
  });
}
