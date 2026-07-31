import 'dart:async';

import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';

import '../domain/entities/euler_angles.dart';
import '../domain/entities/face_observation.dart';
import '../domain/entities/still_capture.dart';
import '../domain/services/face_tracking_service.dart';

/// Rear-camera guided capture via Vision face rectangles (no TrueDepth mesh).
///
/// Native: `RearCaptureManager` on `flutter_face_scan/rear_capture`.
/// Supports still photos and video-frame harvest (sharpest frame per pose).
final class RearFaceTrackingService implements FaceTrackingService {
  RearFaceTrackingService({
    MethodChannel? controlChannel,
    EventChannel? frameChannel,
  })  : _control = controlChannel ?? const MethodChannel(_controlChannelName),
        _frames = frameChannel ?? const EventChannel(_frameChannelName);

  static const String _controlChannelName = 'flutter_face_scan/rear_capture';
  static const String _frameChannelName = 'flutter_face_scan/rear_capture/frames';
  static const String previewViewType = 'flutter_face_scan/rear_preview';

  final MethodChannel _control;
  final EventChannel _frames;

  final StreamController<FaceObservation> _controller =
      StreamController<FaceObservation>.broadcast();

  StreamSubscription<dynamic>? _frameSubscription;
  bool _running = false;
  bool _preferVideo = false;

  int photoWidth = 0;
  int photoHeight = 0;
  int captureWidth = 0;
  int captureHeight = 0;

  /// Last sharpness score from Vision pipeline (diagnostic).
  double lastSharpness = 0;

  bool get preferVideo => _preferVideo;

  @override
  Stream<FaceObservation> get observations => _controller.stream;

  /// Idle preview usually stays on photo preset; scan Start may switch to video.
  Future<void> setPreferVideo(bool value) async {
    if (_preferVideo == value) {
      return;
    }
    _preferVideo = value;
    if (_running) {
      await stop();
      await start();
    }
  }

  @override
  Future<void> start() async {
    if (_running) {
      return;
    }
    _running = true;
    try {
      _frameSubscription ??= _frames.receiveBroadcastStream().listen(
            _onFrame,
            onError: (Object error, StackTrace stackTrace) {
              _controller.addError(error, stackTrace);
            },
          );
      await _control.invokeMethod<void>('start', <String, Object?>{
        'mode': _preferVideo ? 'video' : 'photo',
      });
    } on Object {
      _running = false;
      await _frameSubscription?.cancel();
      _frameSubscription = null;
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (!_running) {
      return;
    }
    _running = false;
    await _frameSubscription?.cancel();
    _frameSubscription = null;
    await _control.invokeMethod<void>('stop');
  }

  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }

  Future<Uint8List?> previewFreeze() async {
    try {
      final Object? raw = await _control.invokeMethod<Object?>('previewFreeze');
      return raw is Uint8List ? raw : null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Start collecting the sharpest video frame for the current pose.
  ///
  /// When [lockAeAwb] is true, settles AE/AWB on the first harvest of a rear
  /// session and re-applies that look for later poses.
  Future<void> beginHarvest({bool lockAeAwb = true}) async {
    try {
      await _control.invokeMethod<void>(
        'beginHarvest',
        <String, Object?>{'lockAeAwb': lockAeAwb},
      );
    } on PlatformException {
      // Ignore — photo path still works.
    } on MissingPluginException {
      // Ignore.
    }
  }

  /// Sharpest harvested video frame (or latest frame fallback).
  Future<StillCapture?> takeHarvestedFrame() async {
    final Map<Object?, Object?>? raw =
        await _control.invokeMethod<Map<Object?, Object?>>('takeHarvestedFrame');
    return _stillFromRaw(raw);
  }

  /// Hi-res rear still. Matrices are identity placeholders (not bake-safe).
  ///
  /// [lockAeAwb]: reuse exposure/WB from the first rear still of this session.
  Future<StillCapture?> captureStill({bool lockAeAwb = true}) async {
    final Map<Object?, Object?>? raw =
        await _control.invokeMethod<Map<Object?, Object?>>(
      'captureStill',
      <String, Object?>{'lockAeAwb': lockAeAwb},
    );
    return _stillFromRaw(raw);
  }

  StillCapture? _stillFromRaw(Map<Object?, Object?>? raw) {
    if (raw == null) {
      return null;
    }
    final Object? jpeg = raw['jpeg'];
    if (jpeg is! Uint8List) {
      return null;
    }
    return StillCapture(
      bytes: jpeg,
      width: (raw['width'] as num?)?.toInt() ?? 0,
      height: (raw['height'] as num?)?.toInt() ?? 0,
      viewMatrix: Matrix4.identity(),
      projectionMatrix: Matrix4.identity(),
      faceTransform: Matrix4.identity(),
    );
  }

  Future<Map<String, Object?>> capabilities() async {
    try {
      final Map<Object?, Object?>? raw =
          await _control.invokeMethod<Map<Object?, Object?>>('capabilities');
      if (raw == null) {
        return const <String, Object?>{};
      }
      return raw.map(
        (Object? k, Object? v) => MapEntry<String, Object?>(k.toString(), v),
      );
    } on Object {
      return const <String, Object?>{};
    }
  }

  void _onFrame(dynamic event) {
    if (event is! Map) {
      return;
    }
    final Map<Object?, Object?> payload = event;
    final int micros = (payload['timestampMicros'] as num?)?.toInt() ?? 0;
    final Duration timestamp = Duration(microseconds: micros);
    final bool isTracked = payload['isTracked'] as bool? ?? false;

    final Object? rawPW = payload['photoWidth'];
    final Object? rawPH = payload['photoHeight'];
    if (rawPW is num && rawPH is num) {
      photoWidth = rawPW.toInt();
      photoHeight = rawPH.toInt();
    }
    final Object? rawW = payload['captureWidth'];
    final Object? rawH = payload['captureHeight'];
    if (rawW is num && rawH is num) {
      captureWidth = rawW.toInt();
      captureHeight = rawH.toInt();
    }
    lastSharpness = (payload['sharpness'] as num?)?.toDouble() ?? 0;

    if (!isTracked) {
      _controller.add(FaceObservation.lost(timestamp));
      return;
    }

    final double yaw = (payload['yawDegrees'] as num?)?.toDouble() ?? 0;
    final double pitch = (payload['pitchDegrees'] as num?)?.toDouble() ?? 0;
    final double roll = (payload['rollDegrees'] as num?)?.toDouble() ?? 0;
    final double cx = (payload['faceCenterX'] as num?)?.toDouble() ?? 0.5;
    final double cy = (payload['faceCenterY'] as num?)?.toDouble() ?? 0.5;
    final double fh = (payload['faceHeight'] as num?)?.toDouble() ?? 0;
    // Rough distance from normalized face height (tunable on device).
    final double distance =
        fh > 0.05 ? (0.18 / fh).clamp(0.15, 1.2) : 0;

    _controller.add(
      FaceObservation(
        timestamp: timestamp,
        isTracked: true,
        eulerAngles: EulerAngles(yaw: yaw, pitch: pitch, roll: roll),
        rawVertices: const <double>[],
        blendshapes: const {},
        // Short vertical segment for frontal center/level gates.
        axisScreenPoints: <Vector2>[
          Vector2(cx, (cy - 0.12).clamp(0.0, 1.0)),
          Vector2(cx, (cy + 0.12).clamp(0.0, 1.0)),
        ],
        distanceMeters: distance,
      ),
    );
  }
}
