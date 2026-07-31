import 'package:flutter_face_scan/features/face_capture/domain/value_objects/pose_tolerance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('CaptureStabilityProfile', () {
    test('fromName parses known values and defaults unknown', () {
      expect(
        CaptureStabilityProfile.fromName('handheld'),
        CaptureStabilityProfile.handheld,
      );
      expect(
        CaptureStabilityProfile.fromName('tripod'),
        CaptureStabilityProfile.tripod,
      );
      expect(
        CaptureStabilityProfile.fromName(null),
        CaptureStabilityProfile.handheld,
      );
      expect(
        CaptureStabilityProfile.fromName('nope'),
        CaptureStabilityProfile.handheld,
      );
    });
  });

  group('PoseTolerance.forProfile', () {
    test('handheld keeps default hold and angle windows', () {
      final PoseTolerance t = PoseTolerance.forProfile(
        CaptureStabilityProfile.handheld,
        targetDistanceMeters: 0.28,
      );
      expect(t.targetDistanceMeters, 0.28);
      expect(t.holdDuration, const Duration(milliseconds: 2500));
      expect(t.holdGrace, const Duration(milliseconds: 350));
      expect(t.yawToleranceDegrees, 5);
      expect(t.pitchToleranceDegrees, 5);
    });

    test('tripod tightens angles and shortens hold', () {
      final PoseTolerance t = PoseTolerance.forProfile(
        CaptureStabilityProfile.tripod,
        targetDistanceMeters: 0.28,
      );
      expect(t.targetDistanceMeters, 0.28);
      expect(t.holdDuration, const Duration(milliseconds: 1200));
      expect(t.holdGrace, const Duration(milliseconds: 150));
      expect(t.yawToleranceDegrees, 3);
      expect(t.pitchToleranceDegrees, 3);
      expect(t.rollToleranceDegrees, 3);
      expect(t.distanceToleranceMeters, 0.04);
      expect(t.maxScreenCenterOffset, lessThan(0.12));
    });
  });
}
