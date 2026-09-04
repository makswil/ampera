import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../data/session_path.dart';
import '../domain/v3/source_paint.dart';
import 'scan_theme.dart';
import 'widgets/camera_corner_frame.dart';

/// Flutter shell around the native SceneKit OBJ platform view.
///
/// App bar, hints, and navigation are Flutter; mesh rendering is SceneKit via
/// [UiKitView] (same pattern as the live camera preview).
///
/// Expression clips use a native **morph** path: shared topology, all vertex
/// buffers in RAM (~KB/frame), and a small texture ring — not full ModelIO
/// meshes per frame (that OOMed / stuttered at 100+ frames).
class ObjModelViewerPage extends StatefulWidget {
  const ObjModelViewerPage({
    required this.objPath,
    required this.title,
    this.subtitle,
    this.sequenceObjPaths,
    this.isDev = false,
    super.key,
  });

  static const String viewType = 'flutter_face_scan/obj_model_preview';

  /// Absolute path to the bake `.obj` (MTL + PNG siblings in same folder).
  final String objPath;

  /// Short consumer title (session name / date — not the bake basename).
  final String title;

  /// Optional secondary line (e.g. expression label).
  final String? subtitle;

  /// Optional expression-sequence frame OBJs (same topology, changing verts).
  final List<String>? sequenceObjPaths;

  /// Dev-only vertex paint (clip vs L/R). Hidden for user/clinician.
  final bool isDev;

  @override
  State<ObjModelViewerPage> createState() => _ObjModelViewerPageState();
}

class _ObjModelViewerPageState extends State<ObjModelViewerPage> {
  /// True until first frame is up; for sequences also until preload finishes.
  bool _showLoading = true;
  Timer? _playTimer;
  int _frameIndex = 0;
  bool _playing = false;
  bool _ready = false;
  MethodChannel? _viewChannel;
  /// Latest path requested while seeking; coalesces in-flight native loads.
  String? _pendingPath;
  bool _pushInFlight = false;
  bool _paintOn = false;
  int _paintBrush = SourcePaintLabel.clip.index;
  bool _paintDirty = false;

  bool get _canPaint {
    return widget.isDev &&
        SourcePaintMap.expressionDirForObj(widget.objPath) != null;
  }

  List<String> get _frames {
    final List<String>? seq = widget.sequenceObjPaths;
    if (seq != null && seq.length > 1) {
      return seq;
    }
    return <String>[widget.objPath];
  }

  bool get _isSequence => _frames.length > 1;

  String get _currentObj => _frames[_frameIndex.clamp(0, _frames.length - 1)];

  @override
  void dispose() {
    _playTimer?.cancel();
    super.dispose();
  }

  void _onPlatformViewCreated(int id) {
    _viewChannel = MethodChannel('flutter_face_scan/obj_model_preview_$id');
    _viewChannel!.setMethodCallHandler(_onNativeCall);
    unawaited(_prepareView());
  }

  Future<void> _onNativeCall(MethodCall call) async {
    if (call.method != 'paintChanged') {
      return;
    }
    final Object? args = call.arguments;
    if (args is! Map) {
      return;
    }
    final Object? raw = args['labels'];
    final List<int> labels;
    if (raw is Uint8List) {
      labels = raw;
    } else if (raw is List) {
      labels = <int>[
        for (final Object? e in raw)
          if (e is num) e.toInt(),
      ];
    } else {
      return;
    }
    await _savePaint(labels);
  }

  Future<void> _savePaint(List<int> labels) async {
    final File? file = SourcePaintMap.fileForObj(widget.objPath);
    if (file == null) {
      return;
    }
    await SourcePaintMap(labels).save(file);
    if (mounted) {
      setState(() => _paintDirty = labels.any((int v) => v != 0));
    }
  }

  Future<void> _loadPaintIntoNative() async {
    final MethodChannel? channel = _viewChannel;
    final File? file = SourcePaintMap.fileForObj(widget.objPath);
    if (channel == null || file == null) {
      return;
    }
    final SourcePaintMap? map = await SourcePaintMap.load(file);
    if (map == null) {
      return;
    }
    try {
      await channel.invokeMethod<void>('setPaintLabels', <String, Object?>{
        'labels': Uint8List.fromList(map.labels),
      });
    } on PlatformException {
      // Overlay stays empty until the user paints.
    }
    if (mounted) {
      setState(() => _paintDirty = !map.isEmpty);
    }
  }

  Future<void> _setPaintOn(bool on) async {
    if (_playing) {
      _playTimer?.cancel();
      _playing = false;
    }
    setState(() => _paintOn = on);
    final MethodChannel? channel = _viewChannel;
    if (channel == null) {
      return;
    }
    try {
      await channel.invokeMethod<void>('setPaintEnabled', <String, Object?>{
        'enabled': on,
      });
      if (on) {
        await channel.invokeMethod<void>('setPaintBrush', <String, Object?>{
          'brush': _paintBrush,
        });
        await _loadPaintIntoNative();
      }
    } on PlatformException {
      // Keep chrome usable.
    }
  }

  Future<void> _setPaintBrush(int brush) async {
    setState(() => _paintBrush = brush);
    try {
      await _viewChannel?.invokeMethod<void>('setPaintBrush', <String, Object?>{
        'brush': brush,
      });
    } on PlatformException {
      // Native brush stays previous.
    }
  }

  Future<void> _clearPaint() async {
    try {
      await _viewChannel?.invokeMethod<void>('clearPaint');
    } on PlatformException {
      // Overlay stays until a successful native clear.
    }
  }

  Future<void> _copyPaintIndices() async {
    final File? file = SourcePaintMap.fileForObj(widget.objPath);
    final SourcePaintMap? map =
        file == null ? null : await SourcePaintMap.load(file);
    final String text = map == null || map.isEmpty
        ? '# source_paint empty'
        : map.compactIndexText();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          map == null || map.isEmpty
              ? 'Keine Markierung — erst malen'
              : 'Verts in der Zwischenablage (${map.indicesFor(SourcePaintLabel.clip).length} Clip)',
        ),
      ),
    );
  }

  Future<void> _prepareView() async {
    final MethodChannel? channel = _viewChannel;
    if (channel == null) {
      return;
    }
    try {
      if (_isSequence) {
        await channel.invokeMethod<void>('preload', <String, Object?>{
          'paths': _frames,
        });
      }
      await channel.invokeMethod<void>('setPath', <String, Object?>{
        'path': _currentObj,
      });
    } on PlatformException {
      // Keep UI usable; scrub may still warm the cache on demand.
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _ready = true;
      _showLoading = false;
    });
  }

  Future<void> _pushPath(String path) async {
    _pendingPath = path;
    final MethodChannel? channel = _viewChannel;
    if (channel == null || _pushInFlight) {
      return;
    }
    _pushInFlight = true;
    try {
      while (_pendingPath != null) {
        final String next = _pendingPath!;
        _pendingPath = null;
        try {
          await channel.invokeMethod<void>('setPath', <String, Object?>{
            'path': next,
          });
        } on PlatformException {
          // Native load failed; keep scrubbing UI responsive.
        }
      }
    } finally {
      _pushInFlight = false;
    }
  }

  void _setFrame(int index) {
    final int clamped = index.clamp(0, _frames.length - 1);
    if (clamped == _frameIndex) {
      return;
    }
    setState(() => _frameIndex = clamped);
    unawaited(_pushPath(_currentObj));
  }

  void _togglePlay() {
    if (!_isSequence || !_ready) {
      return;
    }
    if (_playing) {
      _playTimer?.cancel();
      setState(() => _playing = false);
      return;
    }
    // Restart from the beginning when already on the last frame.
    if (_frameIndex >= _frames.length - 1) {
      _setFrame(0);
    }
    setState(() => _playing = true);
    // ~30 fps playback; native morph swaps verts+albedo without ModelIO.
    _playTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      if (!mounted || !_playing) {
        return;
      }
      final int next = _frameIndex + 1;
      if (next >= _frames.length) {
        _playTimer?.cancel();
        setState(() => _playing = false);
        return;
      }
      _setFrame(next);
    });
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
    final String headline =
        _isSequence ? 'Your expression clip' : 'Your 3D face model';
    final String extraTitle = widget.title.trim();
    final bool kindTitle =
        extraTitle.isEmpty || extraTitle == '3D model' || extraTitle == 'Expression clip';
    final bool kindSub =
        subtitle == '3D model' || subtitle == 'Expression clip';

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
        title: Text(
          <String>[
            headline,
            if (!kindTitle) extraTitle,
            if (subtitle != null && subtitle.isNotEmpty && !kindSub) subtitle,
          ].join(' · '),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: onCanvas,
            fontSize: 17,
            fontWeight: FontWeight.w600,
            letterSpacing: -0.2,
          ),
        ),
        actions: <Widget>[
          if (_canPaint)
            IconButton(
              tooltip: _paintOn ? 'Quellen-Malen aus' : 'Quellen entlang Verts malen',
              onPressed: _ready ? () => unawaited(_setPaintOn(!_paintOn)) : null,
              icon: Icon(
                _paintOn ? Icons.scatter_plot : Icons.scatter_plot_outlined,
                color: _paintOn ? ScanTheme.accent : onCanvas,
              ),
            ),
        ],
      ),
      body: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          UiKitView(
            key: const ValueKey<String>('obj_model_preview'),
            viewType: ObjModelViewerPage.viewType,
            layoutDirection: TextDirection.ltr,
            onPlatformViewCreated: _onPlatformViewCreated,
            creationParams: <String, Object?>{
              'path': widget.objPath,
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
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          color: ScanTheme.accent,
                        ),
                      ),
                      if (_isSequence) ...<Widget>[
                        const SizedBox(height: 14),
                        Text(
                          'Preparing ${_frames.length} frames…',
                          style: TextStyle(
                            color: onCanvas.withValues(alpha: 0.75),
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          if (_isSequence)
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.paddingOf(context).bottom + 16,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (_paintOn) ...<Widget>[
                    _paintBar(canvas: canvas, onCanvas: onCanvas, dark: dark),
                    const SizedBox(height: 10),
                  ],
                  IgnorePointer(
                    child: CameraCornerFrame(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    child: Text(
                      _ready
                          ? 'Slide to move through the clip\nPlay to animate'
                          : 'Loading frames for playback…',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: hintText,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.2,
                        height: 1.45,
                      ),
                    ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Material(
                    color: canvas.withValues(alpha: dark ? 0.82 : 0.90),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
                      child: Row(
                        children: <Widget>[
                          IconButton(
                            onPressed: _ready ? _togglePlay : null,
                            icon: Icon(
                              _playing ? Icons.pause : Icons.play_arrow,
                              color: onCanvas.withValues(
                                alpha: _ready ? 1 : 0.35,
                              ),
                            ),
                            tooltip: _playing ? 'Pause' : 'Play',
                          ),
                          Expanded(
                            child: Slider(
                              value: _frameIndex.toDouble(),
                              min: 0,
                              max: (_frames.length - 1).toDouble(),
                              label: '${_frameIndex + 1}/${_frames.length}',
                              onChanged: !_ready
                                  ? null
                                  : (double v) {
                                      if (_playing) {
                                        _playTimer?.cancel();
                                        setState(() => _playing = false);
                                      }
                                      _setFrame(v.round());
                                    },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            )
          else if (_paintOn)
            Positioned(
              left: 16,
              right: 16,
              bottom: MediaQuery.paddingOf(context).bottom + 16,
              child: _paintBar(canvas: canvas, onCanvas: onCanvas, dark: dark),
            )
          else
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

  Widget _paintBar({
    required Color canvas,
    required Color onCanvas,
    required bool dark,
  }) {
    return Material(
      color: canvas.withValues(alpha: dark ? 0.88 : 0.94),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              _paintDirty
                  ? 'Next Generate follows this paint'
                  : 'Finger paints · rotate off · Auto clears',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: onCanvas.withValues(alpha: 0.78),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: <Widget>[
                  _brushChip('Clip', SourcePaintLabel.clip.index, const Color(0xFF28C85A)),
                  _brushChip('L', SourcePaintLabel.left.index, const Color(0xFFEB3838)),
                  _brushChip('R', SourcePaintLabel.right.index, const Color(0xFF2E6BF5)),
                  _brushChip('Chin', SourcePaintLabel.chin.index, const Color(0xFFFAD028)),
                  _brushChip('Auto', SourcePaintLabel.auto.index, const Color(0xFFB0B0B0)),
                  TextButton(
                    onPressed: () => unawaited(_clearPaint()),
                    child: Text('Clear', style: TextStyle(color: onCanvas)),
                  ),
                  TextButton(
                    onPressed: () => unawaited(_copyPaintIndices()),
                    child: Text('Copy verts', style: TextStyle(color: onCanvas)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _brushChip(String label, int value, Color color) {
    final bool on = _paintBrush == value;
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: ChoiceChip(
        label: Text(label),
        selected: on,
        onSelected: (_) => unawaited(_setPaintBrush(value)),
        selectedColor: color.withValues(alpha: 0.85),
        labelStyle: TextStyle(
          color: on ? Colors.black : color,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
        side: BorderSide(color: color),
      ),
    );
  }
}

/// Loads `baked/bake_manifest.json` next to an expression sequence and returns
/// ordered OBJ paths, or null if missing.
Future<List<String>?> loadExpressionBakeFramePaths(String bakeDirPath) async {
  final File manifest = File('$bakeDirPath/bake_manifest.json');
  if (!manifest.existsSync()) {
    return null;
  }
  final Object? decoded = jsonDecode(await manifest.readAsString());
  if (decoded is! Map<String, dynamic>) {
    return null;
  }
  final List<dynamic> raw =
      decoded['frames'] as List<dynamic>? ?? const <dynamic>[];
  final List<(int, String)> indexed = <(int, String)>[];
  for (final dynamic item in raw) {
    if (item is! Map<String, dynamic>) {
      continue;
    }
    final String? obj = item['obj'] as String?;
    if (obj == null || obj.isEmpty) {
      continue;
    }
    final File? objFile = SessionPath.fileUnderRoot(
      Directory(bakeDirPath),
      obj,
    );
    if (objFile == null) {
      continue;
    }
    final int index = (item['index'] as num?)?.toInt() ?? indexed.length;
    indexed.add((index, objFile.path));
  }
  indexed.sort(((int, String) a, (int, String) b) => a.$1.compareTo(b.$1));
  final List<String> paths = <String>[for (final (int, String) e in indexed) e.$2];
  return paths.isEmpty ? null : paths;
}
