import 'dart:async';

import 'package:flutter_face_scan/features/face_capture/application/capture_bloc.dart';
import 'package:flutter_face_scan/features/face_capture/application/capture_event.dart';
import 'package:flutter_face_scan/features/face_capture/application/capture_status.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/euler_angles.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/face_observation.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/face_pose.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/pose_guidance.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/pose_validation.dart';
import 'package:flutter_face_scan/features/face_capture/domain/services/face_tracking_service.dart';
import 'package:flutter_face_scan/features/face_capture/domain/services/pose_validator.dart';
import 'package:flutter_face_scan/features/face_capture/domain/value_objects/pose_tolerance.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/face_observation_fixtures.dart';

/// In-memory tracking source the test drives frame-by-frame.
class _FakeTrackingService implements FaceTrackingService {
  final StreamController<FaceObservation> _controller =
      StreamController<FaceObservation>.broadcast();
  bool started = false;
  bool stopped = false;

  @override
  Stream<FaceObservation> get observations => _controller.stream;

  @override
  Future<void> start() async => started = true;

  @override
  Future<void> stop() async => stopped = true;

  void emit(FaceObservation observation) => _controller.add(observation);

  Future<void> dispose() => _controller.close();
}

/// Validator with a scripted accept/reject decision, independent of geometry.
class _ScriptedValidator implements PoseValidator {
  _ScriptedValidator(this.onTarget);

  bool onTarget;

  @override
  PoseValidation validate({
    required FacePose pose,
    required FaceObservation observation,
  }) {
    return PoseValidation(
      isOnTarget: onTarget,
      guidance: onTarget
          ? const <PoseGuidance>[PoseGuidance.onTarget]
          : const <PoseGuidance>[PoseGuidance.turnLeft],
      yawError: 0,
      pitchError: 0,
      rollError: 0,
      axisTilt: 0,
      axisResidual: 0,
    );
  }
}

Future<void> _settle() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  late _FakeTrackingService service;
  late DateTime clock;

  setUp(() {
    service = _FakeTrackingService();
    clock = DateTime(2026, 1, 1);
  });
  tearDown(() => service.dispose());

  CaptureBloc buildBloc(PoseValidator validator) => CaptureBloc(
    trackingService: service,
    poseValidator: validator,
    tolerance: const PoseTolerance(holdDuration: Duration(seconds: 1)),
    now: () => clock,
  );

  FaceObservation frame() =>
      observationOnLine(eulerAngles: const EulerAngles.zero());

  test('captures all three poses after holding each for the duration', () async {
    final CaptureBloc bloc = buildBloc(_ScriptedValidator(true));

    bloc.add(const CaptureStarted());
    await _settle();
    expect(service.started, isTrue);
    expect(bloc.state.currentPose, FacePose.frontal);

    for (var i = 0; i < FacePose.captureSequence.length; i++) {
      service.emit(frame()); // hold starts
      await _settle();
      clock = clock.add(const Duration(seconds: 1)); // hold elapses
      service.emit(frame()); // triggers the snapshot
      await _settle();
    }

    expect(bloc.state.status, CaptureStatus.completed);
    expect(bloc.state.snapshots.map((s) => s.pose).toList(), <FacePose>[
      FacePose.frontal,
      FacePose.left40,
      FacePose.right40,
    ]);
    // Camera stays live on completion (preview not frozen); only stopped on close.
    expect(service.stopped, isFalse);
    await bloc.close();
    expect(service.stopped, isTrue);
  });

  test('accumulates hold, tolerates a brief blip, resets on sustained drift',
      () async {
    // holdDuration 1s, holdGrace 200ms.
    final _ScriptedValidator validator = _ScriptedValidator(true);
    final CaptureBloc bloc = CaptureBloc(
      trackingService: service,
      poseValidator: validator,
      tolerance: const PoseTolerance(
        holdDuration: Duration(seconds: 1),
        holdGrace: Duration(milliseconds: 200),
      ),
      now: () => clock,
    );

    bloc.add(const CaptureStarted());
    await _settle();

    // Accumulate 400ms of hold.
    service.emit(frame()); // start (t0)
    await _settle();
    clock = clock.add(const Duration(milliseconds: 400));
    service.emit(frame());
    await _settle();
    expect(bloc.state.holdProgress, closeTo(0.4, 1e-9));

    // Brief blip within the grace window → progress is retained, not reset.
    validator.onTarget = false;
    clock = clock.add(const Duration(milliseconds: 100)); // < 200ms grace
    service.emit(frame());
    await _settle();
    expect(bloc.state.holdProgress, closeTo(0.4, 1e-9));

    // Sustained drift beyond the grace window → reset.
    clock = clock.add(const Duration(milliseconds: 300)); // now 400ms off-target
    service.emit(frame());
    await _settle();
    expect(bloc.state.holdProgress, 0);

    // Hold the full duration → snapshot for frontal.
    validator.onTarget = true;
    service.emit(frame()); // restart hold
    await _settle();
    clock = clock.add(const Duration(seconds: 1));
    service.emit(frame());
    await _settle();
    expect(bloc.state.completedPoses, contains(FacePose.frontal));
    expect(bloc.state.currentPose, FacePose.left40);
    await bloc.close();
  });

  test('a tracking-stream error moves the machine to error state', () async {
    final CaptureBloc bloc = buildBloc(_ScriptedValidator(true));

    bloc.add(const CaptureStarted());
    await _settle();
    bloc.add(const CaptureFailed('sensor lost'));
    await _settle();

    expect(bloc.state.status, CaptureStatus.error);
    expect(bloc.state.errorMessage, 'sensor lost');
    expect(service.stopped, isTrue);
    await bloc.close();
  });
}
