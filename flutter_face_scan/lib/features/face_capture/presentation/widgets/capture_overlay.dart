import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/capture_state.dart';
import '../../application/capture_status.dart';
import '../../domain/entities/capture_actor_mode.dart';
import '../../domain/entities/expression_mode.dart';
import '../../domain/entities/face_pose.dart';
import '../../domain/entities/pose_guidance.dart';
import '../../domain/value_objects/pose_tolerance.dart';
import '../pose_guidance_copy.dart';
import '../scan_theme.dart';
import 'camera_corner_frame.dart';
import 'face_guide_layer.dart';
import 'head_pose_hint.dart';
import 'scan_onboarding_sheet.dart';

/// Pose = still camera, Expression = clip. Same pair as the how-to sheet.
IconData scanModeIcon(ExpressionMode mode) => mode.isExpressionSequence
    ? Icons.videocam_outlined
    : Icons.photo_camera_outlined;

/// Renders guidance for the current [CaptureState].
class CaptureOverlay extends StatelessWidget {
  const CaptureOverlay({
    required this.state,
    this.onStart,
    this.onRetake,
    this.onGenerateModel,
    this.canGenerateModel = false,
    this.hasGeneratedModel = false,
    this.generatingModel = false,
    this.onOpenSettings,
    this.statusLine,
    this.captureBanner,
    this.targetDistanceMeters = PoseTolerance.kDefaultTargetDistanceMeters,
    this.deferPoseGuidance = false,
    this.holdComplete = false,
    this.selectedExpression = ExpressionMode.neutral,
    this.onExpressionChanged,
    this.selectedActorMode = CaptureActorMode.user,
    this.selectedPractitionerFlow = PractitionerFlow.meshThenPhotos,
    this.selectedMeshMotion = MeshMotionMode.device,
    this.selectedClinicianCamera = ClinicianCamera.front,
    this.selectedRearCaptureKind = RearCaptureKind.still,
    this.activeCapturePass,
    this.expressionTitle,
    this.expressionSubtitle,
    this.expressionCountdown,
    this.clipProgress,
    this.hidePoseProgress = false,
    this.suppressOutlineProgress = false,
    super.key,
  });

  final CaptureState state;
  final VoidCallback? onStart;
  final VoidCallback? onRetake;

  /// Build a textured 3D model from the last saved session.
  final VoidCallback? onGenerateModel;

  /// True when a bakeable session is loaded (enables Generate after scan).
  final bool canGenerateModel;

  /// True after a 3D model already exists for this scan (hide Rescan/Generate).
  final bool hasGeneratedModel;

  /// True while bake / ml-wb is in flight (center status + hide actions).
  final bool generatingModel;

  final VoidCallback? onOpenSettings;
  final String? statusLine;
  final String? captureBanner;
  final double targetDistanceMeters;

  /// Hold pose/completed UI while a still handoff (TrueDepth pause) is in flight.
  final bool deferPoseGuidance;

  /// Pose accepted: keep the face-frame ring fully accent until it fades.
  final bool holdComplete;

  /// Idle-mode picker selection (applied on the next Start).
  final ExpressionMode selectedExpression;

  /// Called when the user picks a different expression before Start.
  final ValueChanged<ExpressionMode>? onExpressionChanged;

  /// Actor mode from settings (idle copy only).
  final CaptureActorMode selectedActorMode;

  /// Clinician mesh-source flow from settings (idle + guidance).
  final PractitionerFlow selectedPractitionerFlow;

  /// Mesh-pass motion from settings (idle + guidance).
  final MeshMotionMode selectedMeshMotion;

  /// Clinician camera from settings (idle copy).
  final ClinicianCamera selectedClinicianCamera;

  /// Rear capture kind from settings (idle copy).
  final RearCaptureKind selectedRearCaptureKind;

  /// Active sequential pass (mesh→photo); null for single-pass runs.
  final CapturePass? activeCapturePass;

  /// Expression-sequence coaching (large title).
  final String? expressionTitle;

  /// Optional second line under [expressionTitle].
  final String? expressionSubtitle;

  /// Big countdown digit (3 / 2 / 1) for expression-sequence.
  final int? expressionCountdown;

  /// 0–1 smile-clip recording bar; null hides it. Must not read as finished
  /// until filming actually stops.
  final double? clipProgress;

  /// Hide the 4-pose dots (expression clip is frontal-only).
  final bool hidePoseProgress;

  /// Force outline progress ring off (settle must not look like a scan).
  final bool suppressOutlineProgress;

  static PoseGuidance? primaryGuidance(CaptureState state) {
    final List<PoseGuidance>? guidance = state.lastValidation?.guidance;
    if (guidance == null || guidance.isEmpty) {
      return null;
    }
    return guidance.first;
  }

  @override
  Widget build(BuildContext context) {
    final bool capturing = state.status == CaptureStatus.capturing;
    // Last pose flips status to completed before the still finishes — keep the
    // capture layout until deferPoseGuidance clears.
    final bool inCaptureChrome =
        capturing || deferPoseGuidance || holdComplete;
    final PoseGuidance? primary =
        capturing ? primaryGuidance(state) : null;
    final bool holding = capturing &&
        (primary == PoseGuidance.onTarget ||
            primary == PoseGuidance.holdSteady ||
            (state.holdProgress > 0 &&
                (state.lastValidation?.isOnTarget ?? false)));

    final bool useExpressionCoach =
        expressionTitle != null || expressionCountdown != null;

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        IgnorePointer(
          child: FaceGuideLayer(
            targetDistanceMeters: targetDistanceMeters,
            holdProgress: suppressOutlineProgress ? 0 : state.holdProgress,
            holdComplete: holdComplete,
            guidance: primary,
            active: inCaptureChrome,
          ),
        ),
        SafeArea(
          child: LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Size size = constraints.biggest;
              final Rect guide = FaceGuideLayer.guideBounds(
                size,
                targetDistanceMeters,
              );
              final double guidanceTop = inCaptureChrome
                  ? (guide.top - 110).clamp(48.0, size.height * 0.26)
                  : size.height * 0.34;

              return Stack(
                children: <Widget>[
                  if (!hidePoseProgress)
                    Positioned(
                      top: 8,
                      left: 0,
                      right: 0,
                      child: Center(
                        child: SizedBox(
                          width: (size.width * 0.34).clamp(160.0, 280.0),
                          child: Semantics(
                            label: 'Scan progress, '
                                '${state.completedPoses.length} of '
                                '${FacePose.captureSequence.length} angles captured',
                            child: _PoseProgressBar(state: state),
                          ),
                        ),
                      ),
                    ),
                  // While generating, only show the center status — not the
                  // completed coach ("Expression clip saved") under it.
                  if (useExpressionCoach && !generatingModel)
                    Positioned(
                      top: guidanceTop,
                      left: 24,
                      right: 24,
                      child: _ExpressionCoach(
                        title: expressionTitle,
                        subtitle: expressionSubtitle,
                        countdown: expressionCountdown,
                        progress: clipProgress,
                      ),
                    )
                  else if (!useExpressionCoach) ...<Widget>[
                    if (captureBanner != null)
                      Positioned(
                        top: 56,
                        left: 24,
                        right: 24,
                        child: _CaptureBanner(text: captureBanner!),
                      ),
                    if (!generatingModel)
                      Positioned(
                        top: guidanceTop,
                        left: 28,
                        right: 28,
                        child: _LiveGuidance(
                          state: state,
                          holding: holding,
                          deferPoseGuidance: deferPoseGuidance,
                          statusLine: inCaptureChrome ? null : statusLine,
                          selectedExpression: selectedExpression,
                          selectedActorMode: selectedActorMode,
                          selectedPractitionerFlow: selectedPractitionerFlow,
                          selectedMeshMotion: selectedMeshMotion,
                          selectedClinicianCamera: selectedClinicianCamera,
                          selectedRearCaptureKind: selectedRearCaptureKind,
                          activeCapturePass: activeCapturePass,
                        ),
                      ),
                  ],
                  if (generatingModel)
                    const Positioned.fill(
                      child: IgnorePointer(
                        child: _GeneratingModelStatus(),
                      ),
                    ),
                  if (!inCaptureChrome && !generatingModel)
                    Positioned(
                      left: 28,
                      right: 28,
                      bottom: 28,
                      child: _BottomActions(
                        state: state,
                        onStart: onStart,
                        onRetake: onRetake,
                        onGenerateModel: onGenerateModel,
                        canGenerateModel: canGenerateModel,
                        hasGeneratedModel: hasGeneratedModel,
                        onOpenSettings: onOpenSettings,
                        selectedExpression: selectedExpression,
                        onExpressionChanged: onExpressionChanged,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

/// Centered status while the textured mesh is being created.
class _GeneratingModelStatus extends StatelessWidget {
  const _GeneratingModelStatus();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 36),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: ScanTheme.accent,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              'Creating 3D model…',
              textAlign: TextAlign.center,
              style: ScanTheme.guidanceTitle,
            ),
            const SizedBox(height: 8),
            Text(
              'This can take a moment.\nPlease keep the app open — '
              'leaving or locking the phone pauses generation.',
              textAlign: TextAlign.center,
              style: ScanTheme.guidanceBody,
            ),
          ],
        ),
      ),
    );
  }
}

class _LiveGuidance extends StatelessWidget {
  const _LiveGuidance({
    required this.state,
    required this.holding,
    this.deferPoseGuidance = false,
    this.statusLine,
    this.selectedExpression = ExpressionMode.neutral,
    this.selectedActorMode = CaptureActorMode.user,
    this.selectedPractitionerFlow = PractitionerFlow.meshThenPhotos,
    this.selectedMeshMotion = MeshMotionMode.device,
    this.selectedClinicianCamera = ClinicianCamera.front,
    this.selectedRearCaptureKind = RearCaptureKind.still,
    this.activeCapturePass,
  });

  final CaptureState state;
  final bool holding;
  final bool deferPoseGuidance;
  final String? statusLine;
  final ExpressionMode selectedExpression;
  final CaptureActorMode selectedActorMode;
  final PractitionerFlow selectedPractitionerFlow;
  final MeshMotionMode selectedMeshMotion;
  final ClinicianCamera selectedClinicianCamera;
  final RearCaptureKind selectedRearCaptureKind;
  final CapturePass? activeCapturePass;

  bool get _useCameraCorners =>
      !deferPoseGuidance &&
      (state.status == CaptureStatus.idle ||
          state.status == CaptureStatus.completed);

  /// Guidance copy: head-mesh (front) uses user-style; photo/rear stays orbit.
  CaptureActorMode get _actorMode {
    if (state.status == CaptureStatus.capturing || deferPoseGuidance) {
      return guidanceActorMode(
        actorMode: state.actorMode,
        practitionerFlow: state.practitionerFlow,
        meshMotion: state.meshMotion,
        clinicianCamera: state.clinicianCamera,
        capturePass: activeCapturePass,
      );
    }
    return guidanceActorMode(
      actorMode: selectedActorMode,
      practitionerFlow: selectedPractitionerFlow,
      meshMotion: selectedMeshMotion,
      clinicianCamera: selectedClinicianCamera,
    );
  }

  @override
  Widget build(BuildContext context) {
    final (String? title, String? subtitle) = _copy();
    final PoseGuidance? capturingHint = _directionHint();
    if (title == null &&
        subtitle == null &&
        statusLine == null &&
        capturingHint == null) {
      return const SizedBox.shrink();
    }

    final Widget body = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (capturingHint != null) ...<Widget>[
          HeadPoseHint(guidance: capturingHint),
          const SizedBox(height: 8),
        ],
        if (title != null)
          Text(
            title,
            textAlign: TextAlign.center,
            style: ScanTheme.guidanceTitle.copyWith(
              fontSize: holding ? 24 : 20,
              color: holding ? ScanTheme.accent : Colors.white,
            ),
          ),
        if (subtitle != null) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: ScanTheme.guidanceBody,
          ),
        ],
        if (statusLine != null &&
            state.status != CaptureStatus.capturing &&
            state.status != CaptureStatus.completed) ...<Widget>[
          const SizedBox(height: 6),
          Text(
            statusLine!,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: ScanTheme.accent,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ],
    );

    return Semantics(
      liveRegion: true,
      label: <String?>[title, subtitle].whereType<String>().join('. '),
      child: Align(
        alignment: Alignment.topCenter,
        // Content-based keys crash AnimatedSwitcher on rapid A→B→A title flips.
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 180),
          child: _useCameraCorners
              ? CameraCornerFrame(
                  key: const ValueKey<String>('corners'),
                  child: body,
                )
              : Padding(
                  key: const ValueKey<String>('plain'),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: body,
                ),
        ),
      ),
    );
  }

  (String?, String?) _copy() {
    switch (state.status) {
      case CaptureStatus.idle:
        return (
          PoseGuidanceCopy.idleReady(selectedActorMode),
          PoseGuidanceCopy.idleHeadline(
            selectedExpression,
            actorMode: selectedActorMode,
            practitionerFlow: selectedPractitionerFlow,
            meshMotion: selectedMeshMotion,
            clinicianCamera: selectedClinicianCamera,
            rearCaptureKind: selectedRearCaptureKind,
          ),
        );
      case CaptureStatus.completed:
        // Bloc reaches completed before the last still finishes; keep calm copy
        // until deferPoseGuidance clears (freeze / handoff done).
        if (deferPoseGuidance) {
          return (
            PoseGuidanceCopy.hint(
              PoseGuidance.onTarget,
              actorMode: _actorMode,
            ),
            null,
          );
        }
        return (
          PoseGuidanceCopy.completedHeadline,
          PoseGuidanceCopy.completedSubtitle,
        );
      case CaptureStatus.error:
        final ScanErrorKind kind = classifyScanError(state.errorMessage);
        return (scanErrorTitle(kind), scanErrorBody(kind, state.errorMessage));
      case CaptureStatus.capturing:
        if (deferPoseGuidance) {
          return (
            PoseGuidanceCopy.hint(
              PoseGuidance.onTarget,
              actorMode: _actorMode,
            ),
            null,
          );
        }

        final PoseGuidance? primary = CaptureOverlay.primaryGuidance(state);

        if (holding ||
            primary == PoseGuidance.onTarget ||
            primary == PoseGuidance.holdSteady) {
          return (
            PoseGuidanceCopy.hint(
              PoseGuidance.onTarget,
              actorMode: _actorMode,
            ),
            null,
          );
        }

        if (primary != null) {
          return (
            PoseGuidanceCopy.hint(
              primary,
              expressionScore:
                  state.lastValidation?.expressionScore ?? double.nan,
              actorMode: _actorMode,
            ),
            null,
          );
        }

        final FacePose? pose = state.currentPose;
        if (pose == null) {
          return (null, null);
        }
        return (
          PoseGuidanceCopy.poseInstruction(
            pose,
            actorMode: _actorMode,
          ),
          null,
        );
    }
  }

  PoseGuidance? _directionHint() {
    // Head animation implies the patient turns — hide for clinician orbit.
    if (_actorMode == CaptureActorMode.practitioner) {
      return null;
    }
    if (state.status != CaptureStatus.capturing ||
        holding ||
        deferPoseGuidance) {
      return null;
    }
    final PoseGuidance? primary = CaptureOverlay.primaryGuidance(state);
    if (primary != null) {
      if (HeadPoseHint.showsFor(primary)) {
        return primary;
      }
      return null;
    }
    return HeadPoseHint.forPose(state.currentPose);
  }
}

class _BottomActions extends StatelessWidget {
  const _BottomActions({
    required this.state,
    this.onStart,
    this.onRetake,
    this.onGenerateModel,
    this.canGenerateModel = false,
    this.hasGeneratedModel = false,
    this.onOpenSettings,
    this.selectedExpression = ExpressionMode.neutral,
    this.onExpressionChanged,
  });

  final CaptureState state;
  final VoidCallback? onStart;
  final VoidCallback? onRetake;
  final VoidCallback? onGenerateModel;
  final bool canGenerateModel;
  final bool hasGeneratedModel;
  final VoidCallback? onOpenSettings;
  final ExpressionMode selectedExpression;
  final ValueChanged<ExpressionMode>? onExpressionChanged;

  @override
  Widget build(BuildContext context) {
    final bool showStart =
        (state.status == CaptureStatus.idle ||
            (state.status == CaptureStatus.completed && hasGeneratedModel)) &&
        onStart != null;
    final bool showPostScan =
        state.status == CaptureStatus.completed &&
        onRetake != null &&
        !hasGeneratedModel;
    final bool showGenerate =
        showPostScan && canGenerateModel && onGenerateModel != null;
    final bool isError = state.status == CaptureStatus.error;
    final ScanErrorKind? errorKind =
        isError ? classifyScanError(state.errorMessage) : null;

    if (!showStart && !showPostScan && !isError) {
      return const SizedBox.shrink();
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (isError &&
            errorKind == ScanErrorKind.permission &&
            onOpenSettings != null)
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              style: ScanTheme.primaryButton,
              onPressed: onOpenSettings,
              icon: const Icon(Icons.settings),
              label: const Text('Open Settings'),
            ),
          ),
        if (isError && onStart != null) ...<Widget>[
          if (errorKind == ScanErrorKind.permission) const SizedBox(height: 10),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onStart,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.zero,
                ),
              ),
              child: const Text('Try again'),
            ),
          ),
        ],
        if (showStart)
          _StartRow(
            label: 'Start · ${selectedExpression.label}',
            semanticsLabel: 'Start ${selectedExpression.label} face scan',
            onStart: onStart!,
            expression: selectedExpression,
            onExpressionChanged: onExpressionChanged,
          ),
        if (showPostScan)
          showGenerate
              ? _PostScanActions(
                  onRescan: onRetake!,
                  onGenerateModel: onGenerateModel!,
                  expression: selectedExpression,
                  onExpressionChanged: onExpressionChanged,
                )
              : _StartRow(
                  label: 'Rescan · ${selectedExpression.label}',
                  semanticsLabel: 'Rescan ${selectedExpression.label}',
                  onStart: onRetake!,
                  expression: selectedExpression,
                  onExpressionChanged: onExpressionChanged,
                  icon: Icons.refresh,
                ),
      ],
    );
  }
}

/// Post-scan row: Rescan | Generate 3D (+ optional expression toggle).
class _PostScanActions extends StatelessWidget {
  const _PostScanActions({
    required this.onRescan,
    required this.onGenerateModel,
    required this.expression,
    this.onExpressionChanged,
  });

  final VoidCallback onRescan;
  final VoidCallback onGenerateModel;
  final ExpressionMode expression;
  final ValueChanged<ExpressionMode>? onExpressionChanged;

  static const double _toggleWidth = 52;
  static const double _gap = 8;

  static final ButtonStyle _outline = OutlinedButton.styleFrom(
    foregroundColor: Colors.white,
    side: BorderSide(color: Colors.white.withValues(alpha: 0.35)),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
    textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
  );

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          child: Semantics(
            button: true,
            label: 'Rescan ${expression.label}',
            child: OutlinedButton.icon(
              onPressed: onRescan,
              style: _outline,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Rescan'),
            ),
          ),
        ),
        const SizedBox(width: _gap),
        Expanded(
          flex: 2,
          child: Semantics(
            button: true,
            label: 'Generate 3D model',
            child: FilledButton.icon(
              style: ScanTheme.primaryButton.copyWith(
                padding: const WidgetStatePropertyAll<EdgeInsets>(
                  EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                ),
                textStyle: const WidgetStatePropertyAll<TextStyle>(
                  TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
              ),
              onPressed: onGenerateModel,
              icon: const Icon(Icons.view_in_ar_outlined, size: 18),
              label: const Text('Generate 3D'),
            ),
          ),
        ),
        if (onExpressionChanged != null) ...<Widget>[
          const SizedBox(width: _gap),
          Semantics(
            button: true,
            label: 'Scan mode ${expression.label}, tap to switch',
            child: SizedBox(
              width: _toggleWidth,
              height: 48,
              child: OutlinedButton(
                onPressed: () => onExpressionChanged!(expression.next),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  padding: EdgeInsets.zero,
                  side: BorderSide(
                    color: Colors.white.withValues(alpha: 0.35),
                  ),
                  shape: const RoundedRectangleBorder(
                    borderRadius: BorderRadius.zero,
                  ),
                ),
                child: Icon(scanModeIcon(expression), size: 22),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// Primary action + separate square expression toggle.
///
/// Start is intentionally not full-width (toggle sits beside it). The label is
/// optically shifted so it stays centred on the full row / screen, not on the
/// shorter button alone.
class _StartRow extends StatelessWidget {
  const _StartRow({
    required this.label,
    required this.semanticsLabel,
    required this.onStart,
    required this.expression,
    this.onExpressionChanged,
    this.icon,
  });

  final String label;
  final String semanticsLabel;
  final VoidCallback onStart;
  final ExpressionMode expression;
  final ValueChanged<ExpressionMode>? onExpressionChanged;
  final IconData? icon;

  static const double _toggleWidth = 52;
  static const double _gap = 8;

  @override
  Widget build(BuildContext context) {
    final Widget labelChild = icon == null
        ? Text(label)
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: 20),
              const SizedBox(width: 8),
              Text(label),
            ],
          );

    if (onExpressionChanged == null) {
      return Semantics(
        button: true,
        label: semanticsLabel,
        child: SizedBox(
          width: double.infinity,
          child: FilledButton(
            style: ScanTheme.primaryButton,
            onPressed: onStart,
            child: labelChild,
          ),
        ),
      );
    }

    // Shift label right by half the trailing chrome so it centres on the row.
    const double labelShift = (_toggleWidth + _gap) / 2;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double buttonWidth =
            constraints.maxWidth - _toggleWidth - _gap;
        return Row(
          children: <Widget>[
            SizedBox(
              width: buttonWidth,
              child: Semantics(
                button: true,
                label: semanticsLabel,
                child: FilledButton(
                  style: ScanTheme.primaryButton,
                  onPressed: onStart,
                  child: Transform.translate(
                    offset: const Offset(labelShift, 0),
                    child: labelChild,
                  ),
                ),
              ),
            ),
            const SizedBox(width: _gap),
            Semantics(
              button: true,
              label: 'Scan mode ${expression.label}, tap to switch',
              child: SizedBox(
                width: _toggleWidth,
                height: 48,
                child: OutlinedButton(
                  onPressed: () => onExpressionChanged!(expression.next),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Colors.white,
                    padding: EdgeInsets.zero,
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.35),
                    ),
                    shape: const RoundedRectangleBorder(
                      borderRadius: BorderRadius.zero,
                    ),
                  ),
                  child: Icon(
                    scanModeIcon(expression),
                    size: 22,
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _CaptureBanner extends StatelessWidget {
  const _CaptureBanner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        color: ScanTheme.accent.withValues(alpha: 0.92),
        child: Text(
          text,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
    );
  }
}

/// Large expression-sequence coaching (title + optional countdown digit).
class _ExpressionCoach extends StatelessWidget {
  const _ExpressionCoach({
    this.title,
    this.subtitle,
    this.countdown,
    this.progress,
  });

  final String? title;
  final String? subtitle;
  final int? countdown;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    return CameraCornerFrame(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (countdown != null && countdown! > 0) ...<Widget>[
            Text(
              '$countdown',
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 72,
                fontWeight: FontWeight.w700,
                height: 1,
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (title != null && title!.isNotEmpty)
            Text(
              title!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 26,
                fontWeight: FontWeight.w700,
                height: 1.15,
              ),
            ),
          if (subtitle != null && subtitle!.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              subtitle!,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.85),
                fontSize: 16,
                fontWeight: FontWeight.w500,
                height: 1.3,
              ),
            ),
          ],
          if (progress != null) ...<Widget>[
            const SizedBox(height: 14),
            _SmoothClipBar(progress: progress!),
          ],
        ],
      ),
    );
  }
}

/// Animates toward [progress]. Completing (→1) is slower so the bar filling
/// reads as the end of the process before the scan chrome goes away.
class _SmoothClipBar extends StatefulWidget {
  const _SmoothClipBar({required this.progress});

  final double progress;

  @override
  State<_SmoothClipBar> createState() => _SmoothClipBarState();
}

class _SmoothClipBarState extends State<_SmoothClipBar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late Animation<double> _animation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _animation = AlwaysStoppedAnimation<double>(widget.progress.clamp(0, 1));
  }

  @override
  void didUpdateWidget(_SmoothClipBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final double next = widget.progress.clamp(0.0, 1.0);
    if ((next - oldWidget.progress).abs() < 0.0005) {
      return;
    }
    final double from = _animation.value;
    final bool completing = next >= 0.999;
    _controller
      ..duration = Duration(milliseconds: completing ? 520 : 220)
      ..reset();
    _animation = Tween<double>(begin: from, end: next).animate(
      CurvedAnimation(
        parent: _controller,
        curve: completing ? Curves.easeOutCubic : Curves.easeOut,
      ),
    );
    unawaited(_controller.forward());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[_controller, _animation]),
      builder: (BuildContext context, Widget? _) {
        return ClipRRect(
          borderRadius: BorderRadius.zero,
          child: LinearProgressIndicator(
            value: _animation.value.clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: Colors.white.withValues(alpha: 0.22),
            color: ScanTheme.accent,
          ),
        );
      },
    );
  }
}

class _PoseProgressBar extends StatelessWidget {
  const _PoseProgressBar({required this.state});

  final CaptureState state;

  @override
  Widget build(BuildContext context) {
    final List<FacePose> poses = FacePose.captureSequence;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < poses.length; i++) ...<Widget>[
          if (i > 0)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 3.5),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  height: 1.5,
                  color: state.completedPoses.contains(poses[i - 1])
                      ? ScanTheme.accent.withValues(alpha: 0.55)
                      : Colors.white24,
                ),
              ),
            ),
          _PoseDot(
            pose: poses[i],
            done: state.completedPoses.contains(poses[i]),
            active: state.currentPose == poses[i],
          ),
        ],
      ],
    );
  }
}

class _PoseDot extends StatelessWidget {
  const _PoseDot({
    required this.pose,
    required this.done,
    required this.active,
  });

  final FacePose pose;
  final bool done;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final Color color = done
        ? ScanTheme.accent
        : active
            ? Colors.white
            : Colors.white38;
    return Tooltip(
      message: pose.label,
      child: SizedBox(
        width: 44,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: done
                    ? ScanTheme.accent
                    : active
                        ? Colors.white
                        : Colors.transparent,
                border: Border.all(color: color, width: 1.6),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              pose.label,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: active ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
