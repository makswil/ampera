import 'package:flutter_face_scan/features/face_capture/domain/entities/capture_actor_mode.dart';
import 'package:flutter_face_scan/features/face_capture/domain/value_objects/pose_tolerance.dart';
import 'package:flutter_face_scan/features/face_capture/presentation/debug/debug_settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('DebugSettings.appRole', () {
    test('forceFirstLaunch defaults on and is once per launch', () {
      final DebugSettings debug = DebugSettings();
      expect(debug.forceFirstLaunch, isTrue);
      expect(debug.howToShownThisLaunch, isFalse);
      expect(debug.howToShownThisLaunchFor(smile: true), isFalse);
      debug.markHowToShownThisLaunch();
      expect(debug.howToShownThisLaunch, isTrue);
      expect(debug.howToShownThisLaunchFor(smile: true), isFalse);
      debug.markHowToShownThisLaunchFor(smile: true);
      expect(debug.howToShownThisLaunchFor(smile: true), isTrue);
    });

    test('defaults to user actor', () {
      final DebugSettings debug = DebugSettings();
      expect(debug.appRole, AppRole.user);
      expect(debug.actorMode, CaptureActorMode.user);
      expect(debug.isDev, isFalse);
    });

    test('clinician role locks actorMode to practitioner', () {
      final DebugSettings debug = DebugSettings();
      debug.appRole = AppRole.clinician;
      expect(debug.actorMode, CaptureActorMode.practitioner);
      debug.actorMode = CaptureActorMode.user;
      expect(debug.actorMode, CaptureActorMode.practitioner);
    });

    test('developer keeps actorMode free', () {
      final DebugSettings debug = DebugSettings(appRole: AppRole.developer);
      expect(debug.isDev, isTrue);
      debug.actorMode = CaptureActorMode.practitioner;
      expect(debug.actorMode, CaptureActorMode.practitioner);
      debug.actorMode = CaptureActorMode.user;
      expect(debug.actorMode, CaptureActorMode.user);
    });

    test('leaving developer for user locks actor back', () {
      final DebugSettings debug = DebugSettings(appRole: AppRole.developer);
      debug.actorMode = CaptureActorMode.practitioner;
      debug.appRole = AppRole.user;
      expect(debug.actorMode, CaptureActorMode.user);
    });

    test('stability resets to handheld when leaving clinician', () {
      final DebugSettings debug = DebugSettings(appRole: AppRole.clinician);
      debug.stabilityProfile = CaptureStabilityProfile.tripod;
      debug.appRole = AppRole.user;
      expect(debug.stabilityProfile, CaptureStabilityProfile.handheld);
    });
  });
}
