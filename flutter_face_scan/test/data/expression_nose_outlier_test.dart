import 'package:flutter_face_scan/features/face_capture/data/bake/expression_sequence_baker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('expressionNoseScaleRatio / protrusion', () {
    List<Vector3> mesh({
      required double noseLen,
      double tipZ = 0.04,
      double faceLen = 0.14,
    }) {
      final List<Vector3> v = List<Vector3>.generate(
        1050,
        (_) => Vector3.zero(),
      );
      v[20] = Vector3(0, faceLen * 0.5, 0); // forehead
      v[1047] = Vector3(0, -faceLen * 0.5, 0); // chin
      v[19] = Vector3(0, 0.02, 0.01); // bridge
      v[9] = Vector3(0, 0.02 - noseLen, tipZ); // tip
      return v;
    }

    test('ratio scales with nose length', () {
      final double short = expressionNoseScaleRatio(mesh(noseLen: 0.02));
      final double long = expressionNoseScaleRatio(mesh(noseLen: 0.05));
      expect(long, greaterThan(short));
    });

    test('score drops when tip retracts', () {
      final double ok = expressionNoseScore(mesh(noseLen: 0.035, tipZ: 0.05));
      final double flat = expressionNoseScore(mesh(noseLen: 0.035, tipZ: 0.012));
      expect(ok, greaterThan(flat * 1.5));
    });
  });

  group('expressionNoseOutlierIndices', () {
    test('flags collapsed spike vs median', () {
      final List<double> scores = <double>[0.25, 0.26, 0.08, 0.25, 0.24];
      expect(expressionNoseOutlierIndices(scores), <int>[2]);
    });

    test('flags mild temporal dip', () {
      // Global gate at 0.92 would keep 0.22; temporal vs neighbours catches it.
      final List<double> scores = <double>[
        0.25, 0.25, 0.25, 0.22, 0.25, 0.25, 0.25,
      ];
      expect(expressionNoseOutlierIndices(scores), contains(3));
    });

    test('empty when fewer than 3 frames', () {
      expect(expressionNoseOutlierIndices(<double>[0.1, 0.01]), isEmpty);
    });

    test('empty if gate would wipe sequence', () {
      expect(
        expressionNoseOutlierIndices(
          <double>[0.25, 0.25, 0.25],
          minFractionOfMedian: 1.1,
        ),
        isEmpty,
      );
    });
  });

  group('expressionCentroidOutlierIndices', () {
    test('flags a mid-sequence position jump', () {
      final List<Vector3> centroids = <Vector3>[
        for (int i = 0; i < 6; i++)
          i == 3 ? Vector3(0.02, 0, 0) : Vector3.zero(),
      ];
      expect(
        expressionCentroidOutlierIndices(centroids, faceLen: 0.14),
        <int>[3],
      );
    });
  });
}
