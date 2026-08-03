import 'package:flutter/material.dart';

import '../scan_theme.dart';

/// Camera-viewfinder corner brackets (ready-to-scan chrome).
class CameraCornerFrame extends StatelessWidget {
  const CameraCornerFrame({
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
    this.armLength = 22,
    this.strokeWidth = 3,
    super.key,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double armLength;
  final double strokeWidth;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: CameraCornersPainter(
        color: ScanTheme.accent,
        armLength: armLength,
        strokeWidth: strokeWidth,
      ),
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }
}

class CameraCornersPainter extends CustomPainter {
  const CameraCornersPainter({
    required this.color,
    this.armLength = 22,
    this.strokeWidth = 3,
  });

  final Color color;
  final double armLength;
  final double strokeWidth;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.square;

    void corner(Offset o, double dx, double dy) {
      canvas.drawLine(o, o + Offset(dx * armLength, 0), paint);
      canvas.drawLine(o, o + Offset(0, dy * armLength), paint);
    }

    corner(Offset.zero, 1, 1);
    corner(Offset(size.width, 0), -1, 1);
    corner(Offset(0, size.height), 1, -1);
    corner(Offset(size.width, size.height), -1, -1);
  }

  @override
  bool shouldRepaint(CameraCornersPainter oldDelegate) =>
      oldDelegate.color != color ||
      oldDelegate.armLength != armLength ||
      oldDelegate.strokeWidth != strokeWidth;
}
