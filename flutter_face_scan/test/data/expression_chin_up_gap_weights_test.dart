import 'package:flutter_face_scan/features/face_capture/data/bake/expression_sequence_baker.dart';
import 'package:flutter_face_scan/features/face_capture/domain/constants/face_regions.g.dart';
import 'package:flutter_face_scan/features/face_capture/domain/constants/face_vertex_indices.dart';
import 'package:flutter_face_scan/features/face_capture/domain/v3/view_weights.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

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

  test('expressionScaleBySideWeight zeros midface, keeps outer', () {
    final List<double> w =
        List<double>.filled(FaceRegions.vertexCount, 1);
    final List<double> out = expressionScaleBySideWeight(w);
    expect(out[0], 0);
    expect(out[9], 0); // nose tip
    expect(out[39], 1); // leftOuter in the frozen table
  });

  test('expressionSideSupportWeights skips midface holes (chin-up owns those)', () {
    final List<double> side =
        List<double>.filled(FaceRegions.vertexCount, 0.8);
    final List<double> frontal =
        List<double>.filled(FaceRegions.vertexCount, 0.9);
    frontal[9] = 0; // nose tip midface hole
    frontal[39] = 0; // leftOuter hole
    final List<Vector3> verts = List<Vector3>.generate(
      FaceRegions.vertexCount,
      (_) => Vector3(0, 0, 0),
    );
    verts[9] = Vector3(0, 0, 0); // midline
    verts[39] = Vector3(-0.05, 0, 0); // lateral
    const FaceGuardFrame frame = FaceGuardFrame(
      midlineX: 0,
      halfSpan: 0.074,
      midY: 0,
    );
    final List<double> out = expressionSideSupportWeights(
      side: side,
      frontal: frontal,
      verts: verts,
      frame: frame,
    );
    expect(out[0], 0);
    expect(out[9], 0); // midline hole → not L/R
    expect(out[39], closeTo(0.8, 1e-9)); // outer / lateral hole → L/R ok
  });

  test('expressionSideSupportWeights fills lateral nose-wing holes', () {
    final List<double> side =
        List<double>.filled(FaceRegions.vertexCount, 0.9);
    final List<double> frontal =
        List<double>.filled(FaceRegions.vertexCount, 0.9);
    final List<Vector3> verts = List<Vector3>.generate(
      FaceRegions.vertexCount,
      (_) => Vector3(0, 0, 0),
    );
    // Index with sideWeight 0 but lateral enough for an alar hole.
    const int alar = 10;
    frontal[alar] = 0;
    verts[alar] = Vector3(0.02, 0.01, 0.02); // ~27% of halfSpan 0.074
    const FaceGuardFrame frame = FaceGuardFrame(
      midlineX: 0,
      halfSpan: 0.074,
      midY: 0,
    );
    expect(FaceRegions.sideWeight[alar], 0);
    final List<double> out = expressionSideSupportWeights(
      side: side,
      frontal: frontal,
      verts: verts,
      frame: frame,
    );
    expect(out[alar], closeTo(0.9, 1e-9));
  });

  test('expressionChinUpSupportWeights fills lower midface holes only', () {
    final List<double> chin =
        List<double>.filled(FaceRegions.vertexCount, 0.7);
    final List<double> frontal =
        List<double>.filled(FaceRegions.vertexCount, 0.9);
    final List<Vector3> verts = List<Vector3>.generate(
      FaceRegions.vertexCount,
      (_) => Vector3(1, 1, 1),
    );
    for (final int i in FaceHoleGeometry.mouthOutline) {
      verts[i] = Vector3.zero();
    }
    frontal[9] = 0; // midface hole
    // Place nose tip far from mouth so mouth falloff keeps it.
    verts[9] = Vector3(0, 0.05, 0);
    final List<double> out = expressionChinUpSupportWeights(
      chinUp: chin,
      frontal: frontal,
      verts: verts,
    );
    expect(out[0], 0); // covered by frontal
    expect(out[9], greaterThan(0)); // midface hole → chin-up
    expect(out[39], 0); // outer (sideWeight 1) → scaled out
  });
}
