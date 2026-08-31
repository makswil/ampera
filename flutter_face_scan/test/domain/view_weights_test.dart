import 'dart:math' as math;

import 'package:flutter_face_scan/features/face_capture/domain/v3/view_weights.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('computeGuardFrame', () {
    test('midline / half-span / midY from the axis vertices', () {
      final List<Vector3> verts = <Vector3>[
        Vector3(-2, 1, 0), // 0
        Vector3(0, 0, 0), // 1 (on both axes)
        Vector3(2, -1, 0), // 2
        Vector3(0, 2, 0), // 3
      ];
      final FaceGuardFrame frame = computeGuardFrame(
        verts: verts,
        symmetryAxis: <int>[1, 3], // x = 0, 0 → midline 0
        horizontalAxis: <int>[0, 2], // y = 1, -1 → midY 0
      );
      expect(frame.midlineX, closeTo(0, 1e-9));
      expect(frame.midY, closeTo(0, 1e-9));
      expect(frame.halfSpan, closeTo(2, 1e-9)); // furthest |x| = 2
    });
  });

  group('poseAllowMask', () {
    final List<Vector3> verts = <Vector3>[
      Vector3(-1, 1, 0), // 0: left, upper
      Vector3(-0.1, -1, 0), // 1: near-centre, lower
      Vector3(0.1, 1, 0), // 2: near-centre, upper
      Vector3(1, -1, 0), // 3: right, lower
    ];
    const FaceGuardFrame frame =
        FaceGuardFrame(midlineX: 0, halfSpan: 1, midY: 0);

    test('frontalCenter keeps only the central band (|dx| <= 0.5)', () {
      final List<bool> mask = poseAllowMask(
        verts: verts,
        frame: frame,
        guard: PoseGuard.frontalCenter,
        frontalCenterFraction: 0.5,
      );
      expect(mask, <bool>[false, true, true, false]);
    });

    test('leftHalf keeps negative X, rightHalf keeps positive X', () {
      expect(
        poseAllowMask(verts: verts, frame: frame, guard: PoseGuard.leftHalf),
        <bool>[true, true, false, false],
      );
      expect(
        poseAllowMask(verts: verts, frame: frame, guard: PoseGuard.rightHalf),
        <bool>[false, false, true, true],
      );
    });

    test('lowerHalf keeps y <= midY', () {
      expect(
        poseAllowMask(verts: verts, frame: frame, guard: PoseGuard.lowerHalf),
        <bool>[false, true, false, true],
      );
    });

    test('none allows everything', () {
      expect(
        poseAllowMask(verts: verts, frame: frame, guard: PoseGuard.none),
        everyElement(isTrue),
      );
    });
  });

  group('viewFacingWeights', () {
    // Camera at world (0,0,d) looking toward the origin: view = world→camera =
    // translation(0,0,-d), so inverse(view).translation = (0,0,d).
    final Matrix4 view = Matrix4.translation(Vector3(0, 0, -5));
    final Matrix4 face = Matrix4.identity();

    test('head-on normal → weight 1; grazing normal → 0', () {
      final List<double> w = viewFacingWeights(
        faceLocalVerts: <Vector3>[Vector3.zero(), Vector3.zero()],
        localNormals: <Vector3>[Vector3(0, 0, 1), Vector3(1, 0, 0)],
        viewMatrix: view,
        faceTransform: face,
        allowed: <bool>[true, true],
      );
      expect(w[0], closeTo(1, 1e-9)); // facing 1
      expect(w[1], 0); // facing 0 < minFacing
    });

    test('exponent sharpens the facing weight', () {
      // Normal 60° off the view dir → facing = cos60 = 0.5.
      final Vector3 n = Vector3(math.sin(math.pi / 3), 0, math.cos(math.pi / 3));
      final List<double> w = viewFacingWeights(
        faceLocalVerts: <Vector3>[Vector3.zero()],
        localNormals: <Vector3>[n],
        viewMatrix: view,
        faceTransform: face,
        allowed: <bool>[true],
        exponent: 2,
      );
      expect(w[0], closeTo(0.25, 1e-9)); // 0.5^2
    });

    test('guarded-off vertex is always 0 even when facing head-on', () {
      final List<double> w = viewFacingWeights(
        faceLocalVerts: <Vector3>[Vector3.zero()],
        localNormals: <Vector3>[Vector3(0, 0, 1)],
        viewMatrix: view,
        faceTransform: face,
        allowed: <bool>[false],
      );
      expect(w[0], 0);
    });

    test('faceTransform rotation is applied to the normal', () {
      // Rotate the face -90° about Y: a local +X normal becomes world +Z, which
      // then faces the +Z camera → weight ~1 (was grazing before rotation).
      final Matrix4 rotated = Matrix4.rotationY(-math.pi / 2);
      final List<double> w = viewFacingWeights(
        faceLocalVerts: <Vector3>[Vector3.zero()],
        localNormals: <Vector3>[Vector3(1, 0, 0)],
        viewMatrix: view,
        faceTransform: rotated,
        allowed: <bool>[true],
        exponent: 1,
      );
      expect(w[0], closeTo(1, 1e-6));
    });
  });

  group('viewFacingCosine', () {
    final Matrix4 view = Matrix4.translation(Vector3(0, 0, -5));
    final Matrix4 face = Matrix4.identity();

    test('head-on is 1, grazing is 0, backface is negative', () {
      final List<double> nv = viewFacingCosine(
        faceLocalVerts: <Vector3>[
          Vector3.zero(),
          Vector3.zero(),
          Vector3.zero(),
        ],
        localNormals: <Vector3>[
          Vector3(0, 0, 1),
          Vector3(1, 0, 0),
          Vector3(0, 0, -1),
        ],
        viewMatrix: view,
        faceTransform: face,
      );
      expect(nv[0], closeTo(1, 1e-9));
      expect(nv[1], closeTo(0, 1e-9));
      expect(nv[2], closeTo(-1, 1e-9));
    });
  });

  group('facingQuality', () {
    test('bands match unseen / poor / good thresholds', () {
      expect(facingQuality(0.19), FacingQuality.unseen);
      expect(facingQuality(0.20), FacingQuality.poor);
      expect(facingQuality(0.41), FacingQuality.poor);
      expect(facingQuality(0.42), FacingQuality.good);
      expect(facingQuality(1), FacingQuality.good);
    });
  });

  group('facingFillHint', () {
    test('keeps clip when frontal is good even if a side sees better', () {
      expect(
        facingFillHint(frontal: 0.5, left: 0.99),
        FacingFillHint.clip,
      );
    });

    test('picks the best support when clip is poor and support is better', () {
      expect(
        facingFillHint(frontal: 0.3, left: 0.4, right: 0.8, chinUp: 0.5),
        FacingFillHint.right,
      );
    });

    test('keeps poor clip when support n·v is worse', () {
      expect(
        facingFillHint(frontal: 0.35, left: 0.30, right: 0.28),
        FacingFillHint.clip,
      );
    });

    test('nobody when clip is unseen and support is also grazing', () {
      expect(
        facingFillHint(frontal: 0.1, left: 0.05, right: 0.19),
        FacingFillHint.none,
      );
    });

    test('chin-up wins on a lower-face hole', () {
      expect(
        facingFillHint(frontal: 0.05, left: 0.1, right: 0.1, chinUp: 0.7),
        FacingFillHint.chinUp,
      );
    });
  });

  group('facingBestView', () {
    test('side wins over a merely-good clip if it sees more head-on', () {
      expect(
        facingBestView(frontal: 0.5, left: 0.99),
        FacingFillHint.left,
      );
    });

    test('clip wins when it has the highest n·v', () {
      expect(
        facingBestView(frontal: 0.9, left: 0.4, right: 0.3, chinUp: 0.2),
        FacingFillHint.clip,
      );
    });

    test('clip keeps a tie', () {
      expect(
        facingBestView(frontal: 0.8, left: 0.8),
        FacingFillHint.clip,
      );
    });

    test('nobody when every pose is below minFacing', () {
      expect(
        facingBestView(frontal: 0.1, left: 0.05, right: 0.19),
        FacingFillHint.none,
      );
    });
  });
}
