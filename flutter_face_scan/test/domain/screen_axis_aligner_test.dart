import 'package:flutter_face_scan/features/face_capture/domain/entities/screen_alignment.dart';
import 'package:flutter_face_scan/features/face_capture/domain/logic/screen_axis_aligner.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/face_observation_fixtures.dart';

void main() {
  const ScreenAxisAligner aligner = ScreenAxisAligner();

  test('returns null below the minimum sample count', () {
    expect(aligner.evaluate(straightScreenAxis(count: 3)), isNull);
  });

  test('a centred vertical column is straight, upright and centred', () {
    final ScreenAlignment a = aligner.evaluate(straightScreenAxis())!;

    expect(a.tiltDegrees.abs(), lessThan(0.5));
    expect(a.straightness, lessThan(1e-4));
    expect(a.centerOffsetX.abs(), lessThan(1e-6));
  });

  test('an off-centre column reports a center offset', () {
    final ScreenAlignment a =
        aligner.evaluate(straightScreenAxis(centerX: 0.7))!;

    expect(a.centerOffsetX, closeTo(0.2, 1e-6));
    expect(a.straightness, lessThan(1e-4)); // still straight, just shifted
  });

  test('a tilted column reports tilt but stays straight', () {
    final ScreenAlignment a = aligner.evaluate(straightScreenAxis(tilt: 0.2))!;

    expect(a.tiltDegrees, greaterThan(5));
    expect(a.straightness, lessThan(1e-3));
  });

  test('a bent column (turned head) raises the straightness residual', () {
    final ScreenAlignment straight = aligner.evaluate(straightScreenAxis())!;
    final ScreenAlignment bent =
        aligner.evaluate(straightScreenAxis(bend: 0.3))!;

    expect(bent.straightness, greaterThan(straight.straightness));
    expect(bent.straightness, greaterThan(0.01));
  });
}
