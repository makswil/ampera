import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../domain/entities/face_pose.dart';
import '../../domain/entities/pose_guidance.dart';
import '../scan_theme.dart';

/// Schematic head cue for turn / tilt (CustomPaint, looping motion).
class HeadPoseHint extends StatefulWidget {
  const HeadPoseHint({required this.guidance, super.key});

  final PoseGuidance guidance;

  static bool showsFor(PoseGuidance? g) {
    return g == PoseGuidance.turnLeft ||
        g == PoseGuidance.turnRight ||
        g == PoseGuidance.lookUp ||
        g == PoseGuidance.lookDown ||
        g == PoseGuidance.levelHead ||
        g == PoseGuidance.centerFace;
  }

  static PoseGuidance? forPose(FacePose? pose) {
    if (pose == null) {
      return null;
    }
    return switch (pose) {
      FacePose.frontal => PoseGuidance.centerFace,
      FacePose.left40 => PoseGuidance.turnLeft,
      FacePose.right40 => PoseGuidance.turnRight,
      FacePose.up => PoseGuidance.lookUp,
    };
  }

  @override
  State<HeadPoseHint> createState() => _HeadPoseHintState();
}

class _HeadPoseHintState extends State<HeadPoseHint>
    with SingleTickerProviderStateMixin {
  static const Duration _loopDuration = Duration(milliseconds: 2800);

  late final AnimationController _motion;
  late Animation<double> _yaw;
  late Animation<double> _pitch;

  @override
  void initState() {
    super.initState();
    _motion = AnimationController(vsync: this, duration: _loopDuration);
    _wireAngles(_anglesFor(widget.guidance));
    _startLoop();
  }

  @override
  void didUpdateWidget(HeadPoseHint oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.guidance != widget.guidance) {
      _wireAngles(_anglesFor(widget.guidance));
      _motion.value = 0;
      _startLoop();
    }
  }

  void _startLoop() {
    final (double yaw, double pitch) = _anglesFor(widget.guidance);
    if (yaw == 0 && pitch == 0) {
      _motion
        ..stop()
        ..value = 0;
      return;
    }
    unawaited(_motion.repeat());
  }

  /// Turn → hold → return → pause (weights sum to 100).
  void _wireAngles((double, double) target) {
    Animation<double> axis(double end) {
      return TweenSequence<double>(<TweenSequenceItem<double>>[
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: 0, end: end)
              .chain(CurveTween(curve: Curves.easeInOutCubic)),
          weight: 40,
        ),
        TweenSequenceItem<double>(
          tween: ConstantTween<double>(end),
          weight: 18,
        ),
        TweenSequenceItem<double>(
          tween: Tween<double>(begin: end, end: 0)
              .chain(CurveTween(curve: Curves.easeInOutCubic)),
          weight: 20,
        ),
        TweenSequenceItem<double>(
          tween: ConstantTween<double>(0),
          weight: 22,
        ),
      ]).animate(_motion);
    }

    _yaw = axis(target.$1);
    _pitch = axis(target.$2);
  }

  static (double yaw, double pitch) _anglesFor(PoseGuidance g) {
    return switch (g) {
      PoseGuidance.turnLeft => (-0.95, 0.0),
      PoseGuidance.turnRight => (0.95, 0.0),
      PoseGuidance.lookUp => (0.0, -0.62),
      PoseGuidance.lookDown => (0.0, 0.62),
      PoseGuidance.levelHead => (0.18, 0.08),
      PoseGuidance.centerFace => (0.0, 0.0),
      _ => (0.0, 0.0),
    };
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 56,
      height: 64,
      child: AnimatedBuilder(
        animation: _motion,
        builder: (BuildContext context, Widget? _) {
          return CustomPaint(
            painter: _HeadPosePainter(
              yaw: _yaw.value,
              pitch: _pitch.value,
              guidance: widget.guidance,
            ),
          );
        },
      ),
    );
  }
}

class _HeadPosePainter extends CustomPainter {
  const _HeadPosePainter({
    required this.yaw,
    required this.pitch,
    required this.guidance,
  });

  final double yaw;
  final double pitch;
  final PoseGuidance guidance;

  @override
  void paint(Canvas canvas, Size size) {
    final Offset c = Offset(size.width / 2, size.height * 0.48);
    final double headW = size.width * 0.42;
    final double headH = size.height * 0.46;

    canvas.save();
    canvas.translate(c.dx, c.dy);
    final double sx = math.cos(yaw).abs().clamp(0.32, 1.0);
    canvas.scale(sx, 1.0 - pitch.abs() * 0.14);
    canvas.translate(yaw * headW * 0.62, pitch * headH * 0.62);

    final Rect head = Rect.fromCenter(
      center: Offset.zero,
      width: headW * 2,
      height: headH * 2,
    );

    final Paint fill = Paint()..color = Colors.white.withValues(alpha: 0.12);
    final Paint stroke = Paint()
      ..color = Colors.white.withValues(alpha: 0.92)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;

    final Path egg = Path()
      ..moveTo(head.center.dx, head.top)
      ..cubicTo(
        head.right,
        head.top,
        head.right,
        head.center.dy,
        head.right,
        head.center.dy + head.height * 0.08,
      )
      ..cubicTo(
        head.right,
        head.bottom - head.height * 0.12,
        head.center.dx + head.width * 0.18,
        head.bottom,
        head.center.dx,
        head.bottom,
      )
      ..cubicTo(
        head.center.dx - head.width * 0.18,
        head.bottom,
        head.left,
        head.bottom - head.height * 0.12,
        head.left,
        head.center.dy + head.height * 0.08,
      )
      ..cubicTo(
        head.left,
        head.center.dy,
        head.left,
        head.top,
        head.center.dx,
        head.top,
      )
      ..close();

    canvas.drawPath(egg, fill);
    canvas.drawPath(egg, stroke);

    final double eyeY = -headH * 0.15;
    final double eyeSpread = headW * 0.55;
    final Paint feature = Paint()
      ..color = Colors.white.withValues(alpha: 0.95)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round;

    canvas.drawCircle(
      Offset(-eyeSpread, eyeY),
      2.2 * (1.0 - yaw * 0.55).clamp(0.45, 1.35),
      feature,
    );
    canvas.drawCircle(
      Offset(eyeSpread, eyeY),
      2.2 * (1.0 + yaw * 0.55).clamp(0.45, 1.35),
      feature,
    );
    canvas.drawLine(
      Offset(0, eyeY + 4),
      Offset(yaw.sign * (3 + yaw.abs() * 5), eyeY + 12),
      feature,
    );
    canvas.drawArc(
      Rect.fromCenter(
        center: Offset(yaw * headW * 0.15, headH * 0.35),
        width: headW * 0.7,
        height: 8,
      ),
      0.15,
      math.pi - 0.3,
      false,
      feature,
    );

    canvas.restore();

    final Paint tick = Paint()
      ..color = ScanTheme.accent
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.square
      ..style = PaintingStyle.stroke;
    final Offset tip = Offset(size.width / 2, size.height - 4);
    switch (guidance) {
      case PoseGuidance.turnLeft:
        canvas.drawLine(tip + const Offset(8, 0), tip + const Offset(-8, 0), tick);
        canvas.drawLine(tip + const Offset(-8, 0), tip + const Offset(-2, -5), tick);
        canvas.drawLine(tip + const Offset(-8, 0), tip + const Offset(-2, 5), tick);
      case PoseGuidance.turnRight:
        canvas.drawLine(tip + const Offset(-8, 0), tip + const Offset(8, 0), tick);
        canvas.drawLine(tip + const Offset(8, 0), tip + const Offset(2, -5), tick);
        canvas.drawLine(tip + const Offset(8, 0), tip + const Offset(2, 5), tick);
      case PoseGuidance.lookUp:
        canvas.drawLine(tip + const Offset(0, 6), tip + const Offset(0, -6), tick);
        canvas.drawLine(tip + const Offset(0, -6), tip + const Offset(-5, -1), tick);
        canvas.drawLine(tip + const Offset(0, -6), tip + const Offset(5, -1), tick);
      case PoseGuidance.lookDown:
        canvas.drawLine(tip + const Offset(0, -6), tip + const Offset(0, 6), tick);
        canvas.drawLine(tip + const Offset(0, 6), tip + const Offset(-5, 1), tick);
        canvas.drawLine(tip + const Offset(0, 6), tip + const Offset(5, 1), tick);
      default:
        break;
    }
  }

  @override
  bool shouldRepaint(_HeadPosePainter oldDelegate) =>
      oldDelegate.yaw != yaw ||
      oldDelegate.pitch != pitch ||
      oldDelegate.guidance != guidance;
}
