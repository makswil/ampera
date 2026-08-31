import 'package:flutter_face_scan/features/face_capture/data/bake/expression_sequence_baker.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('assignExpressionExclusiveWeights', () {
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
}
