import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'scan_theme.dart';
import 'widgets/camera_corner_frame.dart';

/// Flutter shell around the native SceneKit OBJ platform view.
///
/// App bar, hints, and navigation are Flutter; mesh rendering is SceneKit via
/// [UiKitView] (same pattern as the live camera preview).
class ObjModelViewerPage extends StatefulWidget {
  const ObjModelViewerPage({
    required this.objPath,
    required this.title,
    this.subtitle,
    super.key,
  });

  static const String viewType = 'flutter_face_scan/obj_model_preview';

  /// Absolute path to the bake `.obj` (MTL + PNG siblings in same folder).
  final String objPath;

  /// Short consumer title (session name / date — not the bake basename).
  final String title;

  /// Optional secondary line (e.g. expression label).
  final String? subtitle;

  @override
  State<ObjModelViewerPage> createState() => _ObjModelViewerPageState();
}

class _ObjModelViewerPageState extends State<ObjModelViewerPage> {
  /// Brief load veil so the platform view doesn't flash empty.
  bool _showLoading = true;
  Timer? _loadingTimer;

  @override
  void initState() {
    super.initState();
    // Native load is async; veil lifts after a short beat (mesh usually ready).
    _loadingTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) {
        setState(() => _showLoading = false);
      }
    });
  }

  @override
  void dispose() {
    _loadingTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool dark = theme.brightness == Brightness.dark;
    final String? subtitle = widget.subtitle?.trim();

    final Color canvas = scheme.surface;
    final Color onCanvas = scheme.onSurface;
    final Color appBarFill = canvas.withValues(alpha: dark ? 0.72 : 0.88);
    final Color vignetteEdge = canvas.withValues(alpha: dark ? 0.60 : 0.40);
    final Color vignetteSoft = canvas.withValues(alpha: dark ? 0.40 : 0.25);
    final Color hintText = onCanvas.withValues(alpha: dark ? 0.90 : 0.78);
    final String fromLine = widget.title.trim().isEmpty
        ? ''
        : 'from ${widget.title.trim()}';

    return Scaffold(
      backgroundColor: canvas,
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        centerTitle: true,
        backgroundColor: appBarFill,
        foregroundColor: onCanvas,
        elevation: 0,
        scrolledUnderElevation: 0,
        surfaceTintColor: Colors.transparent,
        shape: Border(
          bottom: BorderSide(
            color: ScanTheme.accent.withValues(alpha: 0.55),
            width: 1.5,
          ),
        ),
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'Your 3D face model',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: onCanvas,
                fontSize: 17,
                fontWeight: FontWeight.w600,
                letterSpacing: -0.2,
              ),
            ),
            if (fromLine.isNotEmpty ||
                (subtitle != null && subtitle.isNotEmpty))
              Text(
                <String>[
                  if (fromLine.isNotEmpty) fromLine,
                  if (subtitle != null && subtitle.isNotEmpty) subtitle,
                ].join(' · '),
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: onCanvas.withValues(alpha: 0.55),
                  fontSize: 12,
                  fontWeight: FontWeight.w400,
                ),
              ),
          ],
        ),
      ),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          UiKitView(
            viewType: ObjModelViewerPage.viewType,
            layoutDirection: TextDirection.ltr,
            creationParams: <String, Object?>{
              'path': widget.objPath,
              // ARGB int so SceneKit canvas matches Flutter light/dark surface.
              'backgroundArgb': canvas.toARGB32(),
            },
            creationParamsCodec: const StandardMessageCodec(),
            gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{
              Factory<OneSequenceGestureRecognizer>(EagerGestureRecognizer.new),
            },
          ),
          IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: <Color>[
                    vignetteSoft,
                    Colors.transparent,
                    Colors.transparent,
                    vignetteEdge,
                  ],
                  stops: const <double>[0, 0.18, 0.72, 1],
                ),
              ),
            ),
          ),
          if (_showLoading)
            IgnorePointer(
              child: ColoredBox(
                color: canvas.withValues(alpha: 0.55),
                child: Center(
                  child: SizedBox(
                    width: 28,
                    height: 28,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: ScanTheme.accent,
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            left: 20,
            right: 20,
            bottom: MediaQuery.paddingOf(context).bottom + 20,
            child: IgnorePointer(
              child: Center(
                child: CameraCornerFrame(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 28,
                  ),
                  child: Text(
                    'Drag to rotate  ·  Pinch to zoom',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: hintText,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.2,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
