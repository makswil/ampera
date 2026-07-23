import 'package:flutter/material.dart';

import '../../application/capture_state.dart';
import '../../domain/entities/pose_guidance.dart';

/// Compile-time switch for the calibration HUD.
///
/// Defaults to `false`, so in a normal build the `if (kCaptureDebugHud)` guard
/// in `CapturePage` is a dead branch and the tree-shaker removes the HUD and
/// this whole file from the release binary — the production capture flow does
/// NOT depend on any of it.
///
/// Use a profile file instead of typing flags manually:
///   flutter run --dart-define-from-file=dart_defines/dev.json
///
/// Available profiles (see dart_defines/):
///   dev.json        — HUD on, mesh on
///   hud_only.json   — HUD on, mesh off
///   mesh_only.json  — HUD off, mesh on
///   release.json    — everything off (same as no flag)
const bool kCaptureDebugHud =
    bool.fromEnvironment('CAPTURE_DEBUG_HUD');

/// Compile-time switch for the native live mesh + symmetry-axis overlay
/// (green wireframe + red midline dots), used to visually verify the vertex
/// table and L/R mapping. Default `false` → never requested in release.
///
/// See [kCaptureDebugHud] for the profile-file approach.
const bool kFaceMeshOverlay =
    bool.fromEnvironment('FACE_MESH_OVERLAY');

/// Read-only calibration overlay: live Euler angles + symmetry-axis fit, so the
/// two on-device unknowns (Euler sign mapping, vertex-index table) can be
/// eyeballed. Pure presentation — reads only what the BLoC already emits.
///
/// Even when compiled in, tap the badge to hide it instantly.
class CaptureDebugHud extends StatefulWidget {
  const CaptureDebugHud({
    required this.state,
    this.hiRes,
    this.srcRes,
    this.photoRes,
    super.key,
  });

  final CaptureState state;

  /// Whether stills use hi-res capture (null = not yet known).
  final bool? hiRes;

  /// Configured video source resolution, e.g. "1440x1080" (null = unknown).
  final String? srcRes;

  /// Front camera's max still-photo resolution, e.g. "3088x2316".
  final String? photoRes;

  @override
  State<CaptureDebugHud> createState() => _CaptureDebugHudState();
}

class _CaptureDebugHudState extends State<CaptureDebugHud> {
  bool _visible = true;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      // Below the top action row (cancel / share / gear) so it doesn't cover them.
      top: 108,
      right: 12,
      child: SafeArea(
        child: _visible
            ? _Panel(
                state: widget.state,
                hiRes: widget.hiRes,
                srcRes: widget.srcRes,
                photoRes: widget.photoRes,
                onHide: () => setState(() => _visible = false),
              )
            : _ShowBadge(onShow: () => setState(() => _visible = true)),
      ),
    );
  }
}

class _ShowBadge extends StatelessWidget {
  const _ShowBadge({required this.onShow});

  final VoidCallback onShow;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onShow,
      child: const CircleAvatar(
        backgroundColor: Colors.black54,
        child: Icon(Icons.bug_report, color: Colors.greenAccent, size: 20),
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.state,
    required this.onHide,
    this.hiRes,
    this.srcRes,
    this.photoRes,
  });

  final CaptureState state;
  final bool? hiRes;
  final String? srcRes;
  final String? photoRes;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final v = state.lastValidation;
    return Container(
      width: 188,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.greenAccent.withValues(alpha: 0.4)),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          color: Colors.greenAccent,
          fontSize: 11,
          fontFamily: 'Courier',
          height: 1.4,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: <Widget>[
                const Text('CALIBRATION HUD'),
                GestureDetector(
                  onTap: onHide,
                  child: const Icon(
                    Icons.close,
                    size: 14,
                    color: Colors.greenAccent,
                  ),
                ),
              ],
            ),
            const Divider(color: Colors.greenAccent, height: 10),
            _row('pose', state.currentPose?.label ?? '—'),
            _row('target yaw', _deg(state.currentPose?.targetYaw)),
            _row('yaw err', _deg(v?.yawError)),
            _row('pitch err', _deg(v?.pitchError)),
            _row('roll err', _deg(v?.rollError)),
            _row('axis tilt', _deg(v?.axisTilt)),
            _row('axis resid', _meters(v?.axisResidual)),
            _row('2D tilt', _deg(v?.screenAxisTilt)),
            _row('2D straight', _num(v?.screenStraightness)),
            _row('2D center', _num(v?.screenCenterOffset)),
            _row('distance', _cm(v?.distanceMeters)),
            _row('hold', '${(state.holdProgress * 100).round()}%'),
            _row('snapshots', '${state.snapshots.length}'),
            _row('hi-res cap', hiRes == null ? '—' : (hiRes! ? 'YES' : 'no')),
            _row('video res', srcRes ?? '—'),
            _row('photo res', photoRes ?? '—'),
            _row('hint', _hint(v?.guidance)),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text(label),
        Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
      ],
    );
  }

  static String _deg(double? value) =>
      (value == null || value.isNaN) ? '—' : '${value.toStringAsFixed(1)}°';

  static String _meters(double? value) => (value == null || value.isNaN)
      ? '—'
      : '${(value * 1000).toStringAsFixed(1)}mm';

  static String _num(double? value) =>
      (value == null || value.isNaN) ? '—' : value.toStringAsFixed(3);

  static String _cm(double? value) => (value == null || value.isNaN)
      ? '—'
      : '${(value * 100).toStringAsFixed(1)}cm';

  static String _hint(List<PoseGuidance>? guidance) =>
      (guidance == null || guidance.isEmpty) ? '—' : guidance.first.name;
}
