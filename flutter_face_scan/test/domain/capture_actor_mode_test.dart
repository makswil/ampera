import 'package:flutter_face_scan/features/face_capture/domain/entities/capture_actor_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppRole', () {
    test('fromName parses known values and defaults unknown', () {
      expect(AppRole.fromName('user'), AppRole.user);
      expect(AppRole.fromName('clinician'), AppRole.clinician);
      expect(AppRole.fromName('developer'), AppRole.developer);
      expect(AppRole.fromName(null), AppRole.user);
      expect(AppRole.fromName('nope'), AppRole.user);
    });

    test('lockedActorMode locks user/clinician, frees developer', () {
      expect(AppRole.user.lockedActorMode, CaptureActorMode.user);
      expect(
        AppRole.clinician.lockedActorMode,
        CaptureActorMode.practitioner,
      );
      expect(AppRole.developer.lockedActorMode, isNull);
    });
  });

  group('CaptureActorMode', () {
    test('fromName parses known values and defaults unknown', () {
      expect(CaptureActorMode.fromName('user'), CaptureActorMode.user);
      expect(
        CaptureActorMode.fromName('practitioner'),
        CaptureActorMode.practitioner,
      );
      expect(CaptureActorMode.fromName(null), CaptureActorMode.user);
      expect(CaptureActorMode.fromName('nope'), CaptureActorMode.user);
    });
  });

  group('PractitionerFlow', () {
    test('fromName parses known values and defaults unknown', () {
      expect(
        PractitionerFlow.fromName('meshThenPhotos'),
        PractitionerFlow.meshThenPhotos,
      );
      expect(
        PractitionerFlow.fromName('reuseMeshRef'),
        PractitionerFlow.reuseMeshRef,
      );
      expect(PractitionerFlow.fromName(null), PractitionerFlow.meshThenPhotos);
    });
  });

  group('MeshMotionMode', () {
    test('fromName parses known values and defaults unknown', () {
      expect(MeshMotionMode.fromName('head'), MeshMotionMode.head);
      expect(MeshMotionMode.fromName('device'), MeshMotionMode.device);
      expect(MeshMotionMode.fromName(null), MeshMotionMode.device);
      expect(MeshMotionMode.fromName('nope'), MeshMotionMode.device);
    });
  });

  group('guidanceActorMode', () {
    test('front mesh-now + head → user-style guidance', () {
      expect(
        guidanceActorMode(
          actorMode: CaptureActorMode.practitioner,
          practitionerFlow: PractitionerFlow.meshThenPhotos,
          meshMotion: MeshMotionMode.head,
          clinicianCamera: ClinicianCamera.front,
        ),
        CaptureActorMode.user,
      );
    });

    test('rear always practitioner orbit (even if mesh motion is head)', () {
      expect(
        guidanceActorMode(
          actorMode: CaptureActorMode.practitioner,
          practitionerFlow: PractitionerFlow.meshThenPhotos,
          meshMotion: MeshMotionMode.head,
          clinicianCamera: ClinicianCamera.rear,
        ),
        CaptureActorMode.practitioner,
      );
    });

    test('photo pass is orbit even when mesh motion is head', () {
      expect(
        guidanceActorMode(
          actorMode: CaptureActorMode.practitioner,
          practitionerFlow: PractitionerFlow.meshThenPhotos,
          meshMotion: MeshMotionMode.head,
          clinicianCamera: ClinicianCamera.front,
          capturePass: CapturePass.photo,
        ),
        CaptureActorMode.practitioner,
      );
    });

    test('clinician mesh-now + iPad → practitioner guidance', () {
      expect(
        guidanceActorMode(
          actorMode: CaptureActorMode.practitioner,
          practitionerFlow: PractitionerFlow.meshThenPhotos,
          meshMotion: MeshMotionMode.device,
        ),
        CaptureActorMode.practitioner,
      );
    });
  });

  group('ClinicianCamera', () {
    test('fromName parses known values and defaults unknown', () {
      expect(ClinicianCamera.fromName('front'), ClinicianCamera.front);
      expect(ClinicianCamera.fromName('rear'), ClinicianCamera.rear);
      expect(ClinicianCamera.fromName(null), ClinicianCamera.front);
    });
  });

  group('RearCaptureKind', () {
    test('fromName parses known values and defaults unknown', () {
      expect(RearCaptureKind.fromName('still'), RearCaptureKind.still);
      expect(RearCaptureKind.fromName('video'), RearCaptureKind.video);
      expect(RearCaptureKind.fromName(null), RearCaptureKind.still);
    });
  });
}
