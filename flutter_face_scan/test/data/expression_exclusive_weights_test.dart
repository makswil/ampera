import 'package:flutter_face_scan/features/face_capture/data/bake/expression_sequence_baker.dart';
import 'package:flutter_face_scan/features/face_capture/domain/v3/source_paint.dart';
import 'package:flutter_face_scan/features/face_capture/domain/v3/view_weights.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('assignExpressionExclusiveWeights', () {
    test('clip 0.45 (was good at 0.42) yields to stronger left', () {
      final List<double> wF = <double>[0];
      final List<double> wL = <double>[0];
      assignExpressionExclusiveWeights(
        wFrontal: wF,
        wLeft: wL,
        clipNv: <double>[0.45],
        leftNv: <double>[0.80],
        allowSupport: <double>[1],
      );
      expect(wF, <double>[0]);
      expect(wL, <double>[1]);
    });

    test('clip keeps a good vertex even if a side sees it better', () {
      final List<double> wF = <double>[0];
      final List<double> wL = <double>[0];
      assignExpressionExclusiveWeights(
        wFrontal: wF,
        wLeft: wL,
        clipNv: <double>[0.8],
        leftNv: <double>[0.95],
        allowSupport: <double>[1],
      );
      expect(wF, <double>[1]);
      expect(wL, <double>[0]);
    });

    test('poor clip + worse side stays clip', () {
      final List<double> wF = <double>[0];
      final List<double> wL = <double>[0];
      assignExpressionExclusiveWeights(
        wFrontal: wF,
        wLeft: wL,
        clipNv: <double>[0.35],
        leftNv: <double>[0.30],
        allowSupport: <double>[1],
      );
      expect(wF, <double>[1]);
      expect(wL, <double>[0]);
    });

    test('poor clip + still + stronger left → left only', () {
      final List<double> wF = <double>[0];
      final List<double> wL = <double>[0];
      assignExpressionExclusiveWeights(
        wFrontal: wF,
        wLeft: wL,
        clipNv: <double>[0.30],
        leftNv: <double>[0.70],
        allowSupport: <double>[1],
      );
      expect(wF, <double>[0]);
      expect(wL, <double>[1]);
    });

    test('poor clip + moving → clip fallback, no support', () {
      final List<double> wF = <double>[0];
      final List<double> wL = <double>[0];
      assignExpressionExclusiveWeights(
        wFrontal: wF,
        wLeft: wL,
        clipNv: <double>[0.30],
        leftNv: <double>[0.70],
        allowSupport: <double>[0],
      );
      expect(wF, <double>[1]);
      expect(wL, <double>[0]);
    });

    test('orange (partial allow) still picks support exclusively', () {
      final List<double> wF = <double>[0];
      final List<double> wL = <double>[0];
      assignExpressionExclusiveWeights(
        wFrontal: wF,
        wLeft: wL,
        clipNv: <double>[0.25],
        leftNv: <double>[0.80],
        allowSupport: <double>[0.3],
      );
      expect(wF, <double>[0]);
      expect(wL, <double>[1]);
    });

    test('poor clip + chin-up highest → chin-up', () {
      final List<double> wF = <double>[0];
      final List<double> wC = <double>[0];
      assignExpressionExclusiveWeights(
        wFrontal: wF,
        wChin: wC,
        clipNv: <double>[0.10],
        chinNv: <double>[0.85],
        allowSupport: <double>[1],
      );
      expect(wF, <double>[0]);
      expect(wC, <double>[1]);
    });

    test('unseen clip and grazing support → clip fallback', () {
      final List<double> wF = <double>[0];
      final List<double> wL = <double>[0];
      assignExpressionExclusiveWeights(
        wFrontal: wF,
        wLeft: wL,
        clipNv: <double>[0.05],
        leftNv: <double>[0.10],
        allowSupport: <double>[1],
      );
      expect(wF, <double>[1]);
      expect(wL, <double>[0]);
    });

    test('never assigns two poses on the same vertex', () {
      final List<double> wF = List<double>.filled(3, 0);
      final List<double> wL = List<double>.filled(3, 0);
      final List<double> wR = List<double>.filled(3, 0);
      assignExpressionExclusiveWeights(
        wFrontal: wF,
        wLeft: wL,
        wRight: wR,
        clipNv: <double>[0.9, 0.25, 0.25],
        leftNv: <double>[0.5, 0.8, 0.3],
        rightNv: <double>[0.5, 0.3, 0.9],
        allowSupport: <double>[1, 1, 1],
      );
      expect(wF[0] + wL[0] + wR[0], 1);
      expect(wF[1] + wL[1] + wR[1], 1);
      expect(wF[2] + wL[2] + wR[2], 1);
      expect(wF[0], 1);
      expect(wL[1], 1);
      expect(wR[2], 1);
    });
  });

  group('expressionStitchBandWeights', () {
    test('marks only triangles that mix clip with that support', () {
      // 0 clip, 1 left, 2 clip — one tri 0-1-2 mixes clip+left.
      final List<double> band = expressionStitchBandWeights(
        winner: <int>[0, 1, 0, 2],
        supportWinner: 1,
        triangles: <int>[0, 1, 2, 0, 2, 3],
        expandRings: 0,
      );
      expect(band[0], 1);
      expect(band[1], 1);
      expect(band[2], 1);
      expect(band[3], 0);
    });

    test('right seam ignores a left-only triangle', () {
      final List<double> band = expressionStitchBandWeights(
        winner: <int>[0, 1, 1],
        supportWinner: 2,
        triangles: <int>[0, 1, 2],
        expandRings: 0,
      );
      expect(band, <double>[0, 0, 0]);
    });
  });

  group('expressionSkinMatchWeights', () {
    const FaceGuardFrame frame = FaceGuardFrame(
      midlineX: 0,
      halfSpan: 0.08,
      midY: 0,
    );

    // midY±halfSpan band → cheek at y=0 is t=0.5, forehead y=halfSpan is t=1.
    final List<Vector3> verts = <Vector3>[
      Vector3(0, 0, 0), // 0 nose (clip)
      Vector3(-0.05, 0, 0), // 1 left cheek (clip)
      Vector3(-0.05, 0.08, 0), // 2 left forehead (clip)
      Vector3(-0.06, 0, 0), // 3 left outer (support)
      Vector3(0.05, 0, 0), // 4 right cheek (clip)
    ];
    final List<double> facing = <double>[1, 1, 1, 1, 1];

    test('clip left keeps mid-cheek, drops nose and forehead', () {
      final List<double> w = expressionSkinMatchWeights(
        winner: <int>[0, 0, 0, 1, 0],
        keepWinner: 0,
        facingNv: facing,
        verts: verts,
        frame: frame,
        skip: const <int>{},
        side: 1,
      );
      expect(w[0], 0);
      expect(w[1], 1);
      expect(w[2], 0);
      expect(w[3], 0);
      expect(w[4], 0);
    });

    test('left support keeps outer cheek only', () {
      final List<double> w = expressionSkinMatchWeights(
        winner: <int>[0, 0, 0, 1, 0],
        keepWinner: 1,
        facingNv: facing,
        verts: verts,
        frame: frame,
        skip: const <int>{},
        side: 1,
      );
      expect(w[3], 1);
      expect(w[1], 0);
    });

    test('skip and grazing samples are dropped', () {
      final List<double> w = expressionSkinMatchWeights(
        winner: <int>[0, 0, 0, 1, 0],
        keepWinner: 0,
        facingNv: <double>[1, 0.2, 1, 1, 1],
        verts: verts,
        frame: frame,
        skip: const <int>{1},
        side: 1,
      );
      expect(w[1], 0);
    });
  });

  group('expandSourcePaintLabels', () {
    test('rings 0 keeps painted verts only', () {
      final List<int> out = expandSourcePaintLabels(
        labels: <int>[1, 0, 0],
        triangles: <int>[0, 1, 2],
        rings: 0,
      );
      expect(out, <int>[1, 0, 0]);
    });

    test('fills auto neighbours from a clip seed', () {
      final List<int> out = expandSourcePaintLabels(
        labels: <int>[1, 0, 0],
        triangles: <int>[0, 1, 2],
        rings: 1,
      );
      expect(out, <int>[1, 1, 1]);
    });
  });

  group('harmonizeSourcePaintLabels', () {
    test('pairs left/right verts across X and fills the auto mirror', () {
      final List<Vector3> verts = <Vector3>[
        Vector3(-0.04, 0, 0),
        Vector3(0.04, 0, 0),
        Vector3(0, 0, 0),
      ];
      expect(faceMirrorIndex(verts), <int>[1, 0, 2]);
      final List<int> out = harmonizeSourcePaintLabels(
        labels: <int>[
          SourcePaintLabel.left.index,
          SourcePaintLabel.auto.index,
          SourcePaintLabel.auto.index,
        ],
        verts: verts,
        midlineX: 0,
      );
      expect(out[0], SourcePaintLabel.left.index);
      expect(out[1], SourcePaintLabel.right.index);
      expect(out[2], SourcePaintLabel.auto.index);
    });

    test('moves L painted on the right side onto R, then fills the left mirror',
        () {
      final List<Vector3> verts = <Vector3>[
        Vector3(-0.04, 0, 0),
        Vector3(0.04, 0, 0),
      ];
      final List<int> out = harmonizeSourcePaintLabels(
        labels: <int>[
          SourcePaintLabel.auto.index,
          SourcePaintLabel.left.index,
        ],
        verts: verts,
        midlineX: 0,
      );
      expect(out[0], SourcePaintLabel.left.index);
      expect(out[1], SourcePaintLabel.right.index);
    });
  });
}
