import 'package:equatable/equatable.dart';

import '../value_objects/pose_tolerance.dart';
import 'capture_actor_mode.dart';
import 'capture_snapshot.dart';
import 'expression_mode.dart';
import 'face_pose.dart';
import 'still_capture.dart';

/// A completed capture run: the set of accepted per-pose snapshots plus
/// identity/timestamp. Input to [SnapshotRepository.save].
final class CaptureSession extends Equatable {
  const CaptureSession({
    required this.id,
    required this.createdAt,
    required this.snapshots,
    this.stills = const <FacePose, StillCapture>{},
    this.rearStills = const <FacePose, StillCapture>{},
    this.expression = ExpressionMode.neutral,
    this.actorMode = CaptureActorMode.user,
    this.practitionerFlow = PractitionerFlow.meshThenPhotos,
    this.meshMotion = MeshMotionMode.device,
    this.clinicianCamera = ClinicianCamera.front,
    this.rearCaptureKind = RearCaptureKind.still,
    this.meshRefSessionId,
    this.stabilityProfile = CaptureStabilityProfile.handheld,
  });

  /// Stable session identifier (also used as the on-disk folder name).
  final String id;

  /// When the session was assembled.
  final DateTime createdAt;

  /// Accepted snapshots, one per captured pose, in capture order.
  ///
  /// For sequential mesh→rear these are the **mesh-pass** TrueDepth frames
  /// (bake-valid). Rear Vision observations are not stored here.
  final List<CaptureSnapshot> snapshots;

  /// RGB stills paired with [snapshots] (same pose epoch) — bake input.
  final Map<FacePose, StillCapture> stills;

  /// Optional rear enrichment stills (not bake-safe; identity matrices).
  final Map<FacePose, StillCapture> rearStills;

  /// Facial expression held during this run (persisted in the manifest).
  final ExpressionMode expression;

  /// Who operated the device (persisted in the manifest).
  final CaptureActorMode actorMode;

  /// Clinician sub-flow (persisted; ignored for user scans).
  final PractitionerFlow practitionerFlow;

  /// Mesh-pass motion (persisted; meaningful for clinician + mesh now).
  final MeshMotionMode meshMotion;

  /// Clinician photo camera (persisted).
  final ClinicianCamera clinicianCamera;

  /// Rear capture kind (persisted; meaningful for clinician + rear).
  final RearCaptureKind rearCaptureKind;

  /// Earlier session whose mesh was reused ([PractitionerFlow.reuseMeshRef]).
  final String? meshRefSessionId;

  /// Handheld vs tripod acceptance profile used for this run.
  final CaptureStabilityProfile stabilityProfile;

  /// True when this session has a bakeable mesh+front-still set.
  bool get hasBakeableMesh =>
      stills[FacePose.frontal] != null &&
      stills[FacePose.left40] != null &&
      stills[FacePose.right40] != null &&
      snapshots.any(
        (CaptureSnapshot s) =>
            s.pose == FacePose.frontal && s.observation.vertexCount > 0,
      );

  @override
  List<Object?> get props => <Object?>[
    id,
    createdAt,
    snapshots,
    stills,
    rearStills,
    expression,
    actorMode,
    practitionerFlow,
    meshMotion,
    clinicianCamera,
    rearCaptureKind,
    meshRefSessionId,
    stabilityProfile,
  ];
}
