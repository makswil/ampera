import 'package:flutter/material.dart';

import '../../application/capture_state.dart';
import '../../application/capture_status.dart';
import '../../domain/entities/expression_mode.dart';
import '../../domain/entities/face_pose.dart';
import '../../domain/entities/pose_guidance.dart';
import '../../domain/value_objects/pose_tolerance.dart';
import '../pose_guidance_copy.dart';
import '../scan_theme.dart';
import 'face_guide_layer.dart';
import 'head_pose_hint.dart';
import 'scan_onboarding_sheet.dart';

/// Renders guidance for the current [CaptureState].
class CaptureOverlay extends StatelessWidget {
  const CaptureOverlay({
    required this.state,
    this.onStart,
    this.onRetake,
    this.onOpenSettings,
    this.statusLine,
    this.captureBanner,
    this.targetDistanceMeters = PoseTolerance.kDefaultTargetDistanceMeters,
    this.deferPoseGuidance = false,
    this.selectedExpression = ExpressionMode.neutral,
    this.onExpressionChanged,
    super.key,
  });

  final CaptureState state;
  final VoidCallback? onStart;
  final VoidCallback? onRetake;
  final VoidCallback? onOpenSettings;
  final String? statusLine;
  final String? captureBanner;
  final double targetDistanceMeters;

  /// Hold pose/completed UI while a still handoff (TrueDepth pause) is in flight.
  final bool deferPoseGuidance;

  /// Idle-mode picker selection (applied on the next Start).
  final ExpressionMode selectedExpression;

  /// Called when the user picks a different expression before Start.
  final ValueChanged<ExpressionMode>? onExpressionChanged;

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
    final bool inCaptureChrome = capturing || deferPoseGuidance;
    final PoseGuidance? primary =
        capturing ? primaryGuidance(state) : null;
    final bool holding = capturing &&
        (primary == PoseGuidance.onTarget ||
            primary == PoseGuidance.holdSteady ||
            (state.holdProgress > 0 &&
                (state.lastValidation?.isOnTarget ?? false)));

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        IgnorePointer(
          child: FaceGuideLayer(
            targetDistanceMeters: targetDistanceMeters,
            holdProgress: state.holdProgress,
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
                  if (captureBanner != null)
                    Positioned(
                      top: 56,
                      left: 24,
                      right: 24,
                      child: _CaptureBanner(text: captureBanner!),
                    ),
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
                    ),
                  ),
                  if (!inCaptureChrome)
                    Positioned(
                      left: 28,
                      right: 28,
                      bottom: 28,
                      child: _BottomActions(
                        state: state,
                        onStart: onStart,
                        onRetake: onRetake,
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

class _LiveGuidance extends StatelessWidget {
  const _LiveGuidance({
    required this.state,
    required this.holding,
    this.deferPoseGuidance = false,
    this.statusLine,
    this.selectedExpression = ExpressionMode.neutral,
  });

  final CaptureState state;
  final bool holding;
  final bool deferPoseGuidance;
  final String? statusLine;
  final ExpressionMode selectedExpression;

  bool get _useCameraCorners =>
      !deferPoseGuidance &&
      (state.status == CaptureStatus.idle ||
          state.status == CaptureStatus.completed);

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
            state.status != CaptureStatus.capturing) ...<Widget>[
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
              ? _CameraCornerFrame(
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
          PoseGuidanceCopy.idleReady,
          PoseGuidanceCopy.idleHeadline(selectedExpression),
        );
      case CaptureStatus.completed:
        // Bloc reaches completed before the last still finishes; keep calm copy
        // until deferPoseGuidance clears (freeze / handoff done).
        if (deferPoseGuidance) {
          return (PoseGuidanceCopy.hint(PoseGuidance.onTarget), null);
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
          return (PoseGuidanceCopy.hint(PoseGuidance.onTarget), null);
        }

        final PoseGuidance? primary = CaptureOverlay.primaryGuidance(state);

        if (holding ||
            primary == PoseGuidance.onTarget ||
            primary == PoseGuidance.holdSteady) {
          return (PoseGuidanceCopy.hint(PoseGuidance.onTarget), null);
        }

        if (primary != null) {
          return (
            PoseGuidanceCopy.hint(
              primary,
              expressionScore: state.lastValidation?.expressionScore ?? double.nan,
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
            expression: state.expressionMode,
          ),
          null,
        );
    }
  }

  PoseGuidance? _directionHint() {
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

/// Camera-viewfinder corners for idle / success copy.
class _CameraCornerFrame extends StatelessWidget {
  const _CameraCornerFrame({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _CameraCornersPainter(color: ScanTheme.accent),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
        child: child,
      ),
    );
  }
}

class _CameraCornersPainter extends CustomPainter {
  const _CameraCornersPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const double arm = 22;
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0
      ..strokeCap = StrokeCap.square;

    void corner(Offset o, double dx, double dy) {
      canvas.drawLine(o, o + Offset(dx * arm, 0), paint);
      canvas.drawLine(o, o + Offset(0, dy * arm), paint);
    }

    corner(Offset.zero, 1, 1);
    corner(Offset(size.width, 0), -1, 1);
    corner(Offset(0, size.height), 1, -1);
    corner(Offset(size.width, size.height), -1, -1);
  }

  @override
  bool shouldRepaint(_CameraCornersPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _BottomActions extends StatelessWidget {
  const _BottomActions({
    required this.state,
    this.onStart,
    this.onRetake,
    this.onOpenSettings,
    this.selectedExpression = ExpressionMode.neutral,
    this.onExpressionChanged,
  });

  final CaptureState state;
  final VoidCallback? onStart;
  final VoidCallback? onRetake;
  final VoidCallback? onOpenSettings;
  final ExpressionMode selectedExpression;
  final ValueChanged<ExpressionMode>? onExpressionChanged;

  @override
  Widget build(BuildContext context) {
    final bool showStart =
        state.status == CaptureStatus.idle && onStart != null;
    final bool showRetake =
        state.status == CaptureStatus.completed && onRetake != null;
    final bool isError = state.status == CaptureStatus.error;
    final ScanErrorKind? errorKind =
        isError ? classifyScanError(state.errorMessage) : null;

    if (!showStart && !showRetake && !isError) {
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
        if (showRetake)
          _StartRow(
            label: 'Scan again · ${selectedExpression.label}',
            semanticsLabel: 'Scan again ${selectedExpression.label}',
            onStart: onRetake!,
            expression: selectedExpression,
            onExpressionChanged: onExpressionChanged,
            icon: Icons.refresh,
          ),
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
              label: 'Expression ${expression.label}, tap to switch',
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
                    expression == ExpressionMode.smile
                        ? Icons.sentiment_satisfied_alt
                        : Icons.sentiment_neutral,
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
