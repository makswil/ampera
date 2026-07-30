import 'package:equatable/equatable.dart';

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
    this.expression = ExpressionMode.neutral,
  });

  /// Stable session identifier (also used as the on-disk folder name).
  final String id;

  /// When the session was assembled.
  final DateTime createdAt;

  /// Accepted snapshots, one per captured pose, in capture order.
  final List<CaptureSnapshot> snapshots;

  /// Optional RGB still + its camera projection per pose, for UV texture baking.
  final Map<FacePose, StillCapture> stills;

  /// Facial expression held during this run (persisted in the manifest).
  final ExpressionMode expression;

  @override
  List<Object?> get props =>
      <Object?>[id, createdAt, snapshots, stills, expression];
}
