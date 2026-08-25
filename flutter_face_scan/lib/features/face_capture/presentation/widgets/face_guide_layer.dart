import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import '../../domain/entities/pose_guidance.dart';
import '../../domain/value_objects/pose_tolerance.dart';
import '../feedback/capture_feedback.dart';
import '../scan_theme.dart';

/// Face outline guide. Drawn only while [active].
class FaceGuideLayer extends StatefulWidget {
  const FaceGuideLayer({
    required this.targetDistanceMeters,
    required this.holdProgress,
    this.holdComplete = false,
    this.guidance,
    this.active = false,
    super.key,
  });

  final double targetDistanceMeters;
  final double holdProgress;

  /// Pose accepted: draw a full accent ring. Falling edge fades it to the
  /// default outline (with the capture click).
  final bool holdComplete;

  final PoseGuidance? guidance;
  final bool active;

  static Rect guideBounds(Size size, double targetDistanceMeters) {
    final double scale = (PoseTolerance.kReferenceFaceFrameDistanceMeters /
            targetDistanceMeters.clamp(
              PoseTolerance.kMinTargetDistanceMeters,
              PoseTolerance.kMaxTargetDistanceMeters,
            ))
        .clamp(0.85, 1.25);
    final double width = size.width * 0.58 * scale;
    final double height = width / 0.78;
    return Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.52),
      width: width,
      height: height,
    );
  }

  @override
  State<FaceGuideLayer> createState() => _FaceGuideLayerState();
}

class _FaceGuideLayerState extends State<FaceGuideLayer>
    with TickerProviderStateMixin {
  late final AnimationController _pulse;
  late final AnimationController _completeFade;

  static const Duration _completeFadeDuration = Duration(milliseconds: 280);

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _completeFade = AnimationController(
      vsync: this,
      duration: _completeFadeDuration,
    );
    if (widget.holdComplete) {
      _completeFade.value = 1;
    }
    _syncPulse();
  }

  @override
  void didUpdateWidget(FaceGuideLayer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.guidance != widget.guidance ||
        oldWidget.active != widget.active) {
      _syncPulse();
    }
    if (widget.holdComplete && !oldWidget.holdComplete) {
      _completeFade.value = 1;
    } else if (!widget.holdComplete && oldWidget.holdComplete) {
      unawaited(_completeFade.animateTo(0, curve: Curves.easeOut));
    }
  }

  void _syncPulse() {
    final GuidanceVisual visual = visualFor(widget.guidance);
    final bool shouldPulse = widget.active &&
        (visual == GuidanceVisual.closer ||
            visual == GuidanceVisual.farther ||
            visual == GuidanceVisual.center);
    if (shouldPulse) {
      if (!_pulse.isAnimating) {
        unawaited(_pulse.repeat(reverse: true));
      }
    } else {
      _pulse
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    _completeFade.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.active) {
      return const SizedBox.expand();
    }
    final GuidanceVisual visual = visualFor(widget.guidance);
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[_pulse, _completeFade]),
      builder: (BuildContext context, Widget? _) {
        final double fade = _completeFade.value;
        final bool fullRing = widget.holdComplete || fade > 0;
        return CustomPaint(
          painter: _FaceGuidePainter(
            targetDistanceMeters: widget.targetDistanceMeters,
            holdProgress: fullRing ? 1 : widget.holdProgress,
            holdAccentOpacity: fullRing
                ? (widget.holdComplete ? 1 : fade)
                : 1,
            visual: visual,
            pulse: _pulse.value,
          ),
          child: const SizedBox.expand(),
        );
      },
    );
  }
}

class _FaceGuidePainter extends CustomPainter {
  const _FaceGuidePainter({
    required this.targetDistanceMeters,
    required this.holdProgress,
    required this.holdAccentOpacity,
    required this.visual,
    required this.pulse,
  });

  final double targetDistanceMeters;
  final double holdProgress;
  final double holdAccentOpacity;
  final GuidanceVisual visual;
  final double pulse;

  Rect _bounds(Size size) {
    final Rect base = FaceGuideLayer.guideBounds(size, targetDistanceMeters);
    double sizePulse = 1.0;
    if (visual == GuidanceVisual.closer) {
      sizePulse = 1.0 + 0.035 * pulse;
    } else if (visual == GuidanceVisual.farther) {
      sizePulse = 1.0 - 0.035 * pulse;
    }
    if (sizePulse == 1.0) {
      return base;
    }
    return Rect.fromCenter(
      center: base.center,
      width: base.width * sizePulse,
      height: base.height * sizePulse,
    );
  }

  @override
  void paint(Canvas canvas, Size size) {
    final Rect bounds = _bounds(size);
    final Path face = _facePath(bounds);

    final Path dim = Path()
      ..addRect(Offset.zero & size)
      ..addPath(face, Offset.zero)
      ..fillType = PathFillType.evenOdd;
    canvas.drawPath(
      dim,
      Paint()..color = Colors.black.withValues(alpha: 0.28),
    );

    canvas.drawPath(
      face,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.white.withValues(alpha: 0.28),
    );
    canvas.drawPath(
      face,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..strokeJoin = StrokeJoin.round
        ..color = Colors.black.withValues(alpha: 0.78),
    );

    if (holdProgress > 0 && holdAccentOpacity > 0) {
      _drawHoldProgress(
        canvas,
        face,
        holdProgress.clamp(0.0, 1.0),
        holdAccentOpacity.clamp(0.0, 1.0),
      );
    }
  }

  Path _facePath(Rect bounds) {
    final double cx = bounds.center.dx;
    final double top = bounds.top;
    final double bot = bounds.bottom;
    final double left = bounds.left;
    final double right = bounds.right;
    final double h = bounds.height;
    final double w = bounds.width;

    return Path()
      ..moveTo(cx, top)
      ..cubicTo(cx + w * 0.32, top, right, top + h * 0.14, right, top + h * 0.42)
      ..cubicTo(right, top + h * 0.68, cx + w * 0.42, bot, cx, bot)
      ..cubicTo(cx - w * 0.42, bot, left, top + h * 0.68, left, top + h * 0.42)
      ..cubicTo(left, top + h * 0.14, cx - w * 0.32, top, cx, top)
      ..close();
  }

  void _drawHoldProgress(
    Canvas canvas,
    Path face,
    double progress,
    double opacity,
  ) {
    for (final ui.PathMetric metric in face.computeMetrics()) {
      final Path arc = metric.extractPath(0, metric.length * progress);
      canvas.drawPath(
        arc,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.5
          ..strokeCap = StrokeCap.round
          ..color = ScanTheme.accent.withValues(alpha: opacity),
      );
    }
  }

  @override
  bool shouldRepaint(_FaceGuidePainter oldDelegate) =>
      oldDelegate.targetDistanceMeters != targetDistanceMeters ||
      oldDelegate.holdProgress != holdProgress ||
      oldDelegate.holdAccentOpacity != holdAccentOpacity ||
      oldDelegate.visual != visual ||
      oldDelegate.pulse != pulse;
}
