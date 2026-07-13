import 'dart:math' as math;

import 'package:flutter_face_scan/features/face_capture/domain/entities/euler_angles.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/face_observation.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/symmetry_axis.dart';
import 'package:flutter_face_scan/features/face_capture/domain/logic/least_squares_symmetry_axis_extractor.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

import '../support/face_observation_fixtures.dart';

void main() {
  const LeastSquaresSymmetryAxisExtractor extractor =
      LeastSquaresSymmetryAxisExtractor();

  test('returns null for an untracked frame', () {
    expect(extractor.extract(const FaceObservation.lost(Duration.zero)), isNull);
  });

  test('vertical axis has ~0° tilt and ~0 residual', () {
    final FaceObservation obs = observationOnLine(
      eulerAngles: const EulerAngles.zero(),
      direction: Vector3(0, -1, 0),
    );

    final SymmetryAxis axis = extractor.extract(obs)!;

    expect(axis.tiltDegrees.abs(), lessThan(0.5));
    expect(axis.residual, lessThan(1e-6));
    expect(axis.sampleCount, greaterThan(40));
  });

  test('direction is oriented forehead → chin (points downward)', () {
    final FaceObservation obs = observationOnLine(
      eulerAngles: const EulerAngles.zero(),
      direction: Vector3(0, -1, 0),
    );

    final SymmetryAxis axis = extractor.extract(obs)!;

    expect(axis.direction.y, lessThan(0));
  });

  test('a 10° in-plane tilt is recovered', () {
    const double rad = 10 * math.pi / 180;
    // Tilt the downward axis by 10° in the X–Y plane.
    final Vector3 tilted = Vector3(math.sin(rad), -math.cos(rad), 0);
    final FaceObservation obs = observationOnLine(
      eulerAngles: const EulerAngles.zero(),
      direction: tilted,
    );

    final SymmetryAxis axis = extractor.extract(obs)!;

    expect(axis.tiltDegrees.abs(), closeTo(10, 0.5));
  });
}
