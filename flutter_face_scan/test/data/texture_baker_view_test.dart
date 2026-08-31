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

    test('luminanceOnly uses one Rec.709 scale on all channels', () {
      final List<double> gain = const TextureBaker().poseGain(
        reference: _pose(_solid(200, 100, 50)),
        pose: _pose(_solid(100, 50, 25)),
        refWeight: <double>[1, 1, 1],
        poseWeight: <double>[1, 1, 1],
        minSamples: 1,
        luminanceOnly: true,
      );
      expect(gain[0], closeTo(2.0, 1e-6));
      expect(gain[1], gain[0]);
      expect(gain[2], gain[0]);
    });

    test('seam weight prefers stronger min(ref,pose) overlap', () {
      // Equal RGB ratio everywhere; heavier seam sample must not skew.
      final List<double> gain = const TextureBaker().poseGain(
        reference: _pose(_solid(150, 150, 150)),
        pose: _pose(_solid(100, 100, 100)),
        refWeight: <double>[0.05, 1.0, 0.05],
        poseWeight: <double>[0.05, 1.0, 0.05],
        minSamples: 1,
      );
      expect(gain[0], closeTo(1.5, 1e-6));
    });
  });

  group('neutral white balance (poseMeanColor + gainToTarget)', () {
    test('poseMeanColor returns the mean over used vertices', () {
      final List<double>? mean = const TextureBaker().poseMeanColor(
        pose: _pose(_solid(120, 60, 30)),
        weight: <double>[1, 1, 1],
        minSamples: 1,
      );
      expect(mean, isNotNull);
      expect(mean![0], closeTo(120, 1e-9));
      expect(mean[1], closeTo(60, 1e-9));
      expect(mean[2], closeTo(30, 1e-9));
    });

    test('poseMeanColor is null when there are too few used vertices', () {
      final List<double>? mean = const TextureBaker().poseMeanColor(
        pose: _pose(_solid(120, 60, 30)),
        weight: <double>[0, 0, 0], // nothing used
        minSamples: 1,
      );
      expect(mean, isNull);
    });

    test('gainToTarget maps a mean onto the shared target (clamped)', () {
      expect(
        TextureBaker.gainToTarget(<double>[100, 100, 100], <double>[150, 150, 150]),
        <double>[1.5, 1.5, 1.5],
      );
      // Ratio 3 → clamped to 2.0.
      expect(
        TextureBaker.gainToTarget(<double>[50, 50, 50], <double>[150, 150, 150])[0],
        2.0,
      );
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

  test('screen-space frontal copies 2D photo interior, not 3D disc', () {
    // clip.w = z+1 so perspective divide makes 3D-lerp≠2D-lerp of projections.
    final Matrix4 proj = Matrix4.identity()..setEntry(3, 2, 1);
    final img.Image photo = img.Image(width: 32, height: 32, numChannels: 4);
    for (int y = 0; y < 32; y++) {
      for (int x = 0; x < 32; x++) {
        photo.setPixelRgba(x, y, 0, 0, 0, 255);
      }
    }

    BakePose poseAt(List<Vector3> verts) => BakePose(
          image: photo,
          vertices: verts,
          projection: PoseProjection(
            width: 32,
            height: 32,
            viewMatrix: Matrix4.identity(),
            projectionMatrix: proj,
            faceTransform: Matrix4.identity(),
          ),
          viewMatrix: Matrix4.identity(),
          faceTransform: Matrix4.identity(),
        );

    final List<Vector3> verts = <Vector3>[
      Vector3(0.2, 0.2, 0),
      Vector3(-0.2, 0.2, 0),
      Vector3(0, -0.2, 4),
    ];
    final BakePose pose = poseAt(verts);
    final Vector2 pA = pose.projection.projectPixel(verts[0])!;
    final Vector2 pB = pose.projection.projectPixel(verts[1])!;
    final Vector2 pC = pose.projection.projectPixel(verts[2])!;
    final Vector3 mid3 = (verts[0] + verts[1] + verts[2]) / 3;
    final Vector2 p3d = pose.projection.projectPixel(mid3)!;
    final Vector2 p2d = (pA + pB + pC) / 3;

    photo.setPixelRgba(p3d.x.round().clamp(0, 31), p3d.y.round().clamp(0, 31),
        255, 0, 0, 255);
    photo.setPixelRgba(p2d.x.round().clamp(0, 31), p2d.y.round().clamp(0, 31),
        0, 255, 0, 255);

    img.Pixel atlasPixel(Set<int>? screenSpace) {
      final img.Image out = const TextureBaker().bakeViewDependent(
        poses: <WeightedPose>[
          WeightedPose(pose: pose, weight: <double>[1, 1, 1]),
        ],
        uvs: uvs,
        triangles: triangles,
        textureSize: 4,
        screenSpaceFrontalVertices: screenSpace,
      );
      return out.getPixel(1, 1);
    }

    final img.Pixel disc = atlasPixel(null);
    final img.Pixel screen = atlasPixel(const <int>{0, 1, 2});
    // 3D path hits the red mark; 2D eye-cap path hits the green mark.
    expect(disc.r.toInt(), greaterThan(disc.g.toInt()));
    expect(screen.g.toInt(), greaterThan(screen.r.toInt()));
  });

  test('debugRgb mix paints source colours, not photos', () {
    final List<WeightedPose> coloured = <WeightedPose>[
      WeightedPose(
        pose: _pose(_solid(0, 0, 0)),
        weight: <double>[1, 1, 1],
        debugRgb: const <int>[255, 0, 0],
      ),
      WeightedPose(
        pose: _pose(_solid(0, 0, 0)),
        weight: <double>[1, 1, 1],
        debugRgb: const <int>[0, 0, 255],
      ),
    ];
    final img.Image out = const TextureBaker().bakeViewDependent(
      poses: coloured,
      uvs: uvs,
      triangles: triangles,
      textureSize: 4,
      blend: true,
    );
    final ({int r, int g, int b}) c = firstCovered(out);
    expect(c.r, closeTo(128, 2));
    expect(c.g, 0);
    expect(c.b, closeTo(128, 2));
  });

  test('debugTint keeps photo detail while shifting toward debugRgb', () {
    final List<WeightedPose> tinted = <WeightedPose>[
      WeightedPose(
        pose: _pose(_solid(200, 200, 200)),
        weight: <double>[1, 1, 1],
        debugRgb: const <int>[0, 255, 0],
      ),
    ];
    final img.Image out = const TextureBaker().bakeViewDependent(
      poses: tinted,
      uvs: uvs,
      triangles: triangles,
      textureSize: 4,
      blend: true,
      debugTint: 0.5,
    );
    final ({int r, int g, int b}) c = firstCovered(out);
    // lerp(200,0,0.5)=100, lerp(200,255,0.5)=228, blue same 100.
    expect(c.r, closeTo(100, 2));
    expect(c.g, closeTo(228, 2));
    expect(c.b, closeTo(100, 2));
  });

  test('bakeVertexRgb paints a solid per-vertex colour', () {
    final img.Image out = const TextureBaker().bakeVertexRgb(
      rgb: <int>[0, 255, 0, 0, 255, 0, 0, 255, 0],
      uvs: uvs,
      triangles: triangles,
      textureSize: 4,
    );
    final ({int r, int g, int b}) c = firstCovered(out);
    expect(c.r, 0);
    expect(c.g, 255);
    expect(c.b, 0);
  });
}
