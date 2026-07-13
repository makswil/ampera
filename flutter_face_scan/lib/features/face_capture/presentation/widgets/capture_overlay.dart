import 'package:flutter/material.dart';

import '../../application/capture_state.dart';
import '../../application/capture_status.dart';
import '../../domain/entities/face_pose.dart';
import '../../domain/entities/pose_guidance.dart';
import '../pose_guidance_copy.dart';

/// Pure presentation: renders guidance for the current [CaptureState].
///
/// Stateless and free of business logic — it only formats what the BLoC emits,
/// which keeps it cheap to widget-test and re-skin.
class CaptureOverlay extends StatelessWidget {
  const CaptureOverlay({
    required this.state,
    this.onStart,
    this.statusLine,
    super.key,
  });

  final CaptureState state;

  /// Starts (or restarts) the scan. When null, no Start button is shown.
  final VoidCallback? onStart;

  /// Optional post-capture status (e.g. "Baking texture…") shown under the
  /// guidance message. Null = nothing extra.
  final String? statusLine;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        // "Face frame" oval — a placement guide so the face stays a consistent
        // size/position; the distance gate does the actual enforcement.
        const IgnorePointer(
          child: CustomPaint(painter: _FaceFramePainter()),
        ),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _PoseProgressBar(state: state),
                const Spacer(),
                _GuidanceCard(
                  state: state,
                  onStart: onStart,
                  statusLine: statusLine,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// Draws a centred vertical oval as a face placement guide.
class _FaceFramePainter extends CustomPainter {
  const _FaceFramePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final Rect oval = Rect.fromCenter(
      center: Offset(size.width / 2, size.height * 0.46),
      width: size.width * 0.66,
      height: size.height * 0.62,
    );
    final Paint stroke = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white54;
    canvas.drawOval(oval, stroke);
  }

  @override
  bool shouldRepaint(_FaceFramePainter oldDelegate) => false;
}

class _PoseProgressBar extends StatelessWidget {
  const _PoseProgressBar({required this.state});

  final CaptureState state;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: <Widget>[
        for (final FacePose pose in FacePose.captureSequence)
          _PoseChip(
            pose: pose,
            done: state.completedPoses.contains(pose),
            active: state.currentPose == pose,
          ),
      ],
    );
  }
}

class _PoseChip extends StatelessWidget {
  const _PoseChip({
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
        ? Colors.greenAccent
        : active
        ? Colors.white
        : Colors.white38;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          done ? Icons.check_circle : Icons.radio_button_unchecked,
          color: color,
        ),
        const SizedBox(height: 4),
        Text(pose.label, style: TextStyle(color: color, fontSize: 12)),
      ],
    );
  }
}

class _GuidanceCard extends StatelessWidget {
  const _GuidanceCard({required this.state, this.onStart, this.statusLine});

  final CaptureState state;
  final VoidCallback? onStart;
  final String? statusLine;

  @override
  Widget build(BuildContext context) {
    final String message = _message();
    final bool capturing = state.status == CaptureStatus.capturing;
    final bool showStart = !capturing && onStart != null;
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white, fontSize: 18),
          ),
          if (capturing) ...<Widget>[
            const SizedBox(height: 16),
            LinearProgressIndicator(value: state.holdProgress),
          ],
          if (statusLine != null) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              statusLine!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.greenAccent, fontSize: 13),
            ),
          ],
          if (showStart) ...<Widget>[
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onStart,
              icon: const Icon(Icons.play_arrow),
              label: const Text('Start'),
            ),
          ],
        ],
      ),
    );
  }

  String _message() {
    switch (state.status) {
      case CaptureStatus.idle:
        return 'Ready to scan';
      case CaptureStatus.completed:
        return 'All angles captured ✓';
      case CaptureStatus.error:
        return state.errorMessage ?? 'Tracking error';
      case CaptureStatus.capturing:
        final List<PoseGuidance>? guidance = state.lastValidation?.guidance;
        if (guidance == null || guidance.isEmpty) {
          final FacePose? pose = state.currentPose;
          return pose == null ? '' : PoseGuidanceCopy.poseInstruction(pose);
        }
        return PoseGuidanceCopy.hint(state.lastValidation!.guidance.first);
    }
  }
}
