import 'package:flutter_face_scan/features/face_capture/data/bake/texture_baker.dart';
import 'package:flutter_face_scan/features/face_capture/domain/v3/texture_projection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart';

img.Image _solid(int r, int g, int b) {
  final img.Image im = img.Image(width: 4, height: 4, numChannels: 4);
  for (int y = 0; y < 4; y++) {
    for (int x = 0; x < 4; x++) {
      im.setPixelRgba(x, y, r, g, b, 255);
    }
  }
  return im;
}

BakePose _pose(img.Image image) => BakePose(
      image: image,
      // Three coincident verts at the origin → any barycentric point projects to
      // the image centre (a valid, solid-colour pixel).
      vertices: <Vector3>[Vector3.zero(), Vector3.zero(), Vector3.zero()],
      projection: PoseProjection(
        width: 4,
        height: 4,
        viewMatrix: Matrix4.identity(),
        projectionMatrix: Matrix4.identity(),
        faceTransform: Matrix4.identity(),
      ),
      viewMatrix: Matrix4.identity(),
      faceTransform: Matrix4.identity(),
    );

void main() {
  // One triangle covering the whole 4×4 atlas.
  final List<double> uvs = <double>[0, 0, 1, 0, 0, 1];
  final List<int> triangles = <int>[0, 1, 2];

  // Pose 0 = red (higher weight), pose 1 = blue (lower weight).
  final List<WeightedPose> poses = <WeightedPose>[
    WeightedPose(pose: _pose(_solid(255, 0, 0)), weight: <double>[1, 1, 1]),
    WeightedPose(pose: _pose(_solid(0, 0, 255)), weight: <double>[0.5, 0.5, 0.5]),
  ];

  ({int r, int g, int b}) firstCovered(img.Image out) {
    for (int y = 0; y < out.height; y++) {
      for (int x = 0; x < out.width; x++) {
        final img.Pixel p = out.getPixel(x, y);
        if (p.a > 0) {
          return (r: p.r.toInt(), g: p.g.toInt(), b: p.b.toInt());
        }
      }
    }
    return (r: -1, g: -1, b: -1);
  }

  test('best-only takes the single highest-weight pose (pure red, no mix)', () {
    final img.Image out = const TextureBaker().bakeViewDependent(
      poses: poses,
      uvs: uvs,
      triangles: triangles,
      textureSize: 4,
      blend: false,
    );
    final ({int r, int g, int b}) c = firstCovered(out);
    expect(c.r, 255);
    expect(c.g, 0);
    expect(c.b, 0); // no blue bleed
  });

  test('weighted blend mixes both poses (blue bleeds in)', () {
    final img.Image out = const TextureBaker().bakeViewDependent(
      poses: poses,
      uvs: uvs,
      triangles: triangles,
      textureSize: 4,
      blend: true,
    );
    final ({int r, int g, int b}) c = firstCovered(out);
    // (1*255red + 0.5*255blue) / 1.5 → red ~170, blue ~85.
    expect(c.r, closeTo(170, 1));
    expect(c.b, closeTo(85, 1));
    expect(c.b, greaterThan(0)); // proves it mixed
  });

  group('poseGain', () {
    test('matches a darker pose up to the reference (ratio gain)', () {
      final List<double> gain = const TextureBaker().poseGain(
        reference: _pose(_solid(150, 150, 150)),
        pose: _pose(_solid(100, 100, 100)),
        refWeight: <double>[1, 1, 1],
        poseWeight: <double>[1, 1, 1],
        minSamples: 1,
      );
      expect(gain[0], closeTo(1.5, 1e-6));
      expect(gain[1], closeTo(1.5, 1e-6));
      expect(gain[2], closeTo(1.5, 1e-6));
    });

    test('too little overlap → no correction ([1,1,1])', () {
      final List<double> gain = const TextureBaker().poseGain(
        reference: _pose(_solid(150, 150, 150)),
        pose: _pose(_solid(100, 100, 100)),
        refWeight: <double>[1, 1, 1],
        poseWeight: <double>[0, 0, 0], // no overlap
        minSamples: 1,
      );
      expect(gain, <double>[1, 1, 1]);
    });

    test('gain is clamped to the [0.5, 2.0] range', () {
      final List<double> gain = const TextureBaker().poseGain(
        reference: _pose(_solid(250, 250, 250)),
        pose: _pose(_solid(50, 50, 50)), // raw ratio 5 → clamp 2
        refWeight: <double>[1, 1, 1],
        poseWeight: <double>[1, 1, 1],
        minSamples: 1,
      );
      expect(gain[0], 2.0);
    });
  });

  test('gain is applied to the chosen pose in best-only', () {
    final List<WeightedPose> gained = <WeightedPose>[
      WeightedPose(pose: _pose(_solid(10, 10, 10)), weight: <double>[0.1, 0.1, 0.1]),
      WeightedPose(
        pose: _pose(_solid(100, 100, 100)),
        weight: <double>[1, 1, 1],
        gain: <double>[2, 2, 2], // 100 * 2 = 200
      ),
    ];
    final img.Image out = const TextureBaker().bakeViewDependent(
      poses: gained,
      uvs: uvs,
      triangles: triangles,
      textureSize: 4,
      blend: false,
    );
    final ({int r, int g, int b}) c = firstCovered(out);
    expect(c.r, 200);
    expect(c.g, 200);
    expect(c.b, 200);
  });
}
