import 'dart:typed_data';

import '../domain/constants/capture_defaults.dart';
import '../domain/entities/capture_session.dart';
import '../domain/entities/face_pose.dart';
import '../domain/entities/still_capture.dart';

/// Applies on-device ml-wb JPEG correction to every pose still in [session].
///
/// Frontal is always processed first so [matchFrontal] can reuse its Kelvin.
/// Returns the original session unchanged when no stills are present or the
/// corrector fails (caller keeps raw stills).
Future<({CaptureSession session, String note})> applySessionWhiteBalance({
  required CaptureSession session,
  required Future<WhiteBalanceCorrection?> Function({
    required List<Uint8List> jpegs,
    required bool matchFrontal,
    required double targetKelvin,
  }) correct,
  required bool matchFrontal,
  double targetKelvin = CaptureDefaults.neutralKelvin,
}) async {
  final List<FacePose> order = <FacePose>[
    FacePose.frontal,
    for (final FacePose p in FacePose.captureSequence)
      if (p != FacePose.frontal && session.stills.containsKey(p)) p,
  ];
  final List<FacePose> present = <FacePose>[
    for (final FacePose p in order)
      if (session.stills[p] != null) p,
  ];
  if (present.isEmpty) {
    return (session: session, note: 'ml-wb: no stills');
  }

  final List<Uint8List> inputs = <Uint8List>[
    for (final FacePose p in present) session.stills[p]!.bytes,
  ];
  final WhiteBalanceCorrection? result = await correct(
    jpegs: inputs,
    matchFrontal: matchFrontal,
    targetKelvin: targetKelvin,
  );
  if (result == null || !result.ok || result.jpegs.length != present.length) {
    return (
      session: session,
      note: 'ml-wb FAILED (${result?.error ?? 'no response'}) — raw stills'
          '${result?.timingSummary != null ? ' · ${result!.timingSummary}' : ''}',
    );
  }

  final Map<FacePose, StillCapture> stills =
      Map<FacePose, StillCapture>.of(session.stills);
  for (int i = 0; i < present.length; i++) {
    final StillCapture old = stills[present[i]]!;
    stills[present[i]] = StillCapture(
      bytes: result.jpegs[i],
      width: old.width,
      height: old.height,
      viewMatrix: old.viewMatrix,
      projectionMatrix: old.projectionMatrix,
      faceTransform: old.faceTransform,
    );
  }

  final String mode =
      matchFrontal ? 'frontal' : '${CaptureDefaults.neutralKelvin.round()} K';
  final String timing =
      result.timingSummary != null ? ' · ${result.timingSummary}' : '';
  return (
    session: CaptureSession(
      id: session.id,
      createdAt: session.createdAt,
      snapshots: session.snapshots,
      stills: stills,
      rearStills: session.rearStills,
      expression: session.expression,
      actorMode: session.actorMode,
      practitionerFlow: session.practitionerFlow,
      meshMotion: session.meshMotion,
      clinicianCamera: session.clinicianCamera,
      rearCaptureKind: session.rearCaptureKind,
      meshRefSessionId: session.meshRefSessionId,
      stabilityProfile: session.stabilityProfile,
    ),
    note: 'ml-wb OK → ${result.targetKelvin.round()} K ($mode)$timing',
  );
}

/// Portable white-balance result (decoupled from the platform service type).
final class WhiteBalanceCorrection {
  const WhiteBalanceCorrection({
    required this.ok,
    required this.jpegs,
    required this.targetKelvin,
    this.error,
    this.timingSummary,
  });

  final bool ok;
  final List<Uint8List> jpegs;
  final double targetKelvin;
  final String? error;
  final String? timingSummary;
}
