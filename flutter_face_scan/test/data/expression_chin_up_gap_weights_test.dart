import 'package:flutter_face_scan/features/face_capture/data/bake/expression_sequence_baker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('expressionChinUpGapWeights', () {
    test('keeps chin-up where others are zero', () {
      final List<double> out = expressionChinUpGapWeights(
        candidate: <double>[0.9, 0.5, 0],
        coveredBy: <List<double>>[
          <double>[0, 0, 1],
        ],
      );
      expect(out[0], closeTo(0.9, 1e-9));
      expect(out[1], closeTo(0.5, 1e-9));
      expect(out[2], 0);
    });

    test('kills chin-up where frontal already covers', () {
      final List<double> out = expressionChinUpGapWeights(
        candidate: <double>[1, 1],
        coveredBy: <List<double>>[
          <double>[0.5, 0.02],
        ],
        coverageKill: 0.08,
      );
      expect(out[0], 0);
      expect(out[1], closeTo(1 * (1 - 0.02 / 0.08), 1e-9));
    });

    test('uses max across all covering poses', () {
      final List<double> out = expressionChinUpGapWeights(
        candidate: <double>[1],
        coveredBy: <List<double>>[
          <double>[0.01],
          <double>[0.2],
        ],
        coverageKill: 0.08,
      );
      expect(out[0], 0);
    });
  });
}
