import 'package:flutter_face_scan/features/face_capture/domain/v3/vertex_motion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('motionQuality', () {
    test('bands match 2 mm / 8 mm', () {
      expect(motionQuality(0.001), MotionQuality.still);
      expect(motionQuality(0.002), MotionQuality.slight);
      expect(motionQuality(0.007), MotionQuality.slight);
      expect(motionQuality(0.008), MotionQuality.moving);
    });
  });

  group('motionAllowSupport', () {
    test('1 on still, 0 on moving, ramp in between', () {
      expect(motionAllowSupport(0.001), 1);
      expect(motionAllowSupport(0.002), 1);
      expect(motionAllowSupport(0.008), 0);
      expect(motionAllowSupport(0.020), 0);
      final double mid = motionAllowSupport(0.005);
      expect(mid, greaterThan(0));
      expect(mid, lessThan(1));
    });
  });

  group('meanVertices', () {
    test('averages index-aligned sources', () {
      final List<Vector3>? mean = meanVertices(<List<Vector3>>[
        <Vector3>[Vector3(0, 0, 0), Vector3(2, 0, 0)],
        <Vector3>[Vector3(2, 2, 0), Vector3(4, 0, 0)],
      ]);
      expect(mean, isNotNull);
      expect(mean![0].x, closeTo(1, 1e-9));
      expect(mean[0].y, closeTo(1, 1e-9));
      expect(mean[1].x, closeTo(3, 1e-9));
    });

    test('null when empty', () {
      expect(meanVertices(const <List<Vector3>>[]), isNull);
    });
  });

  group('maxVertexTravel', () {
    test('keeps the largest excursion per vertex', () {
      final List<Vector3> rest = <Vector3>[
        Vector3.zero(),
        Vector3(1, 0, 0),
      ];
      final List<double> d = maxVertexTravel(
        rest: rest,
        clips: <List<Vector3>>[
          <Vector3>[Vector3(0.003, 0, 0), Vector3(1.001, 0, 0)],
          <Vector3>[Vector3(0.010, 0, 0), Vector3(1.000, 0, 0)],
        ],
      );
      expect(d[0], closeTo(0.010, 1e-9));
      expect(d[1], closeTo(0.001, 1e-9));
    });
  });
}
