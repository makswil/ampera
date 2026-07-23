import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:vector_math/vector_math_64.dart';

import '../domain/entities/face_observation.dart';
import '../domain/entities/still_capture.dart';
import '../domain/services/face_tracking_service.dart';
import 'mappers/face_anchor_mapper.dart';

/// iOS ARKit (TrueDepth) implementation of [FaceTrackingService], backed by a
/// **native platform channel** (see `ios/Runner/FaceTracking/*.swift`).
///
/// arkit_plugin is intentionally not used: it does not expose the
/// `ARFaceGeometry` vertex buffer to Dart, which the symmetry-axis logic and V3
/// reconstruction need. The native side runs an `ARFaceTrackingConfiguration`
/// session and streams each frame's transform, full vertex list and
/// blendshapes over an [EventChannel].
///
/// This is the ONLY Dart class that knows about the channel wire format; it
/// decodes the payload and hands plain primitives to [FaceAnchorMapper], so
/// everything upstream stays device-independent and testable.
final class ArkitFaceTrackingService implements FaceTrackingService {
  ArkitFaceTrackingService({
    FaceAnchorMapper mapper = const FaceAnchorMapper(),
    MethodChannel? controlChannel,
    EventChannel? frameChannel,
  })  : _mapper = mapper,
        _control = controlChannel ?? const MethodChannel(_controlChannelName),
        _frames = frameChannel ?? const EventChannel(_frameChannelName);

  static const String _controlChannelName = 'flutter_face_scan/face_tracking';
  static const String _frameChannelName =
      'flutter_face_scan/face_tracking/frames';

  final FaceAnchorMapper _mapper;
  final MethodChannel _control;
  final EventChannel _frames;

  final StreamController<FaceObservation> _controller =
      StreamController<FaceObservation>.broadcast();

  StreamSubscription<dynamic>? _frameSubscription;
  bool _running = false;

  /// Constant triangle topology; sent once by native, cached and re-attached to
  /// every frame so snapshots carry it.
  List<int> _triangleIndices = const <int>[];

  /// Constant per-vertex UVs; sent once by native (same one-shot as topology),
  /// cached and re-attached to every frame so snapshots carry them for baking.
  List<double> _textureCoordinates = const <double>[];

  /// Whether stills use `captureHighResolutionFrame` (sent once by native).
  /// Null until the first frame of a session; for the calibration HUD.
  bool? _hiResCapture;

  bool? get hiResCapture => _hiResCapture;

  /// Configured video-format resolution (px); 0 until known. For the HUD.
  int _captureWidth = 0;
  int _captureHeight = 0;

  int get captureWidth => _captureWidth;
  int get captureHeight => _captureHeight;

  /// Front camera's max still-photo resolution (px); 0 until known. For the HUD.
  int _photoWidth = 0;
  int _photoHeight = 0;

  int get photoWidth => _photoWidth;
  int get photoHeight => _photoHeight;

  @override
  Stream<FaceObservation> get observations => _controller.stream;

  @override
  Future<void> start() async {
    if (_running) {
      return;
    }
    _running = true;
    _frameSubscription ??= _frames.receiveBroadcastStream().listen(
          _onFrame,
          onError: _controller.addError,
        );
    await _control.invokeMethod<void>('start');
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

  /// Portrait JPEG + its projection for the current frame (see [StillCapture]);
  /// null if no frame / no tracked face. ARKit-backend capability.
  ///
  /// When [hiRes] is true, native pauses ARKit, shoots a full-res AVCapture photo
  /// (front TrueDepth, ~7 MP) registered with ARKit's view/projection matrices,
  /// then resumes ARKit. Falls back to the ARKit video-res still on any failure,
  /// so a pose is never lost. Defaults to the stable ARKit video path.
  Future<StillCapture?> captureStill({bool hiRes = false}) async {
    final Map<Object?, Object?>? raw =
        await _control.invokeMethod<Map<Object?, Object?>>(
      'captureStill',
      <String, Object?>{'hiRes': hiRes},
    );
    if (raw == null) {
      return null;
    }
    final Object? jpeg = raw['jpeg'];
    final Matrix4? view = _decodeTransform(raw['viewMatrix']);
    final Matrix4? projection = _decodeTransform(raw['projectionMatrix']);
    final Matrix4? faceTransform = _decodeTransform(raw['faceTransform']);
    if (jpeg is! Uint8List ||
        view == null ||
        projection == null ||
        faceTransform == null) {
      return null;
    }
    return StillCapture(
      bytes: jpeg,
      width: (raw['width'] as num?)?.toInt() ?? 0,
      height: (raw['height'] as num?)?.toInt() ?? 0,
      viewMatrix: view,
      projectionMatrix: projection,
      faceTransform: faceTransform,
    );
  }

  /// Native iOS share sheet for [paths] (baked model files). No share plugin.
  Future<void> shareFiles(List<String> paths) async {
    await _control.invokeMethod<void>('shareFiles', <String, Object?>{
      'paths': paths,
    });
  }

  /// Toggles the native verification overlay (live mesh wireframe + symmetry-axis
  /// dots). Not part of [FaceTrackingService] — it is a debug/diagnostic aid
  /// specific to this ARKit backend. [axisIndices] should be the Dart-owned
  /// symmetry-axis index table so the rendered midline mirrors the logic.
  Future<void> setOverlay({
    required bool showMesh,
    required List<int> axisIndices,
  }) async {
    await _control.invokeMethod<void>('configureOverlay', <String, Object?>{
      'showMesh': showMesh,
      'axisIndices': axisIndices,
    });
  }

  void _onFrame(dynamic event) {
    if (event is! Map) {
      return;
    }
    final Map<Object?, Object?> payload = event;
    final int micros = (payload['timestampMicros'] as num?)?.toInt() ?? 0;
    final Duration timestamp = Duration(microseconds: micros);

    // Topology + UVs are sent once per session; cache and reuse every frame.
    final Object? rawTopology = payload['triangleIndices'];
    if (rawTopology != null) {
      _triangleIndices = _decodeIntList(rawTopology);
    }
    final Object? rawUVs = payload['textureCoordinates'];
    if (rawUVs != null) {
      _textureCoordinates = _decodeRawVertices(rawUVs);
    }
    final Object? rawHiRes = payload['hiResCapture'];
    if (rawHiRes is bool) {
      _hiResCapture = rawHiRes;
    }
    final Object? rawW = payload['captureWidth'];
    final Object? rawH = payload['captureHeight'];
    if (rawW is num && rawH is num) {
      _captureWidth = rawW.toInt();
      _captureHeight = rawH.toInt();
    }
    final Object? rawPW = payload['photoWidth'];
    final Object? rawPH = payload['photoHeight'];
    if (rawPW is num && rawPH is num) {
      _photoWidth = rawPW.toInt();
      _photoHeight = rawPH.toInt();
    }

    final bool isTracked = payload['isTracked'] as bool? ?? false;
    if (!isTracked) {
      _controller.add(FaceObservation.lost(timestamp));
      return;
    }

    _controller.add(
      _mapper.map(
        timestamp: timestamp,
        transform: _decodeTransform(payload['transform']) ?? Matrix4.identity(),
        rawVertices: _decodeRawVertices(payload['vertices']),
        blendShapes: _decodeBlendShapes(payload['blendShapes']),
        cameraTransform: _decodeTransform(payload['cameraTransform']),
        axisScreenPoints: _decodeScreenPoints(payload['axisScreenPoints']),
        triangleIndices: _triangleIndices,
        textureCoordinates: _textureCoordinates,
      ),
    );
  }

  /// Column-major 4×4 matrix as 16 floats (matches simd_float4x4 layout).
  /// Returns null when absent/malformed so the mapper can fall back.
  Matrix4? _decodeTransform(Object? raw) {
    final List<double> values = _asDoubleList(raw);
    if (values.length != 16) {
      return null;
    }
    return Matrix4.fromList(values);
  }

  /// Flat [x0,y0, x1,y1, …] normalized screen points.
  List<Vector2> _decodeScreenPoints(Object? raw) {
    final List<double> flat = _asDoubleList(raw);
    final List<Vector2> result = <Vector2>[];
    for (int i = 0; i + 1 < flat.length; i += 2) {
      result.add(Vector2(flat[i], flat[i + 1]));
    }
    return result;
  }

  /// Flat [x0,y0,z0, …] vertex buffer. Passed through with no per-vertex
  /// allocation: the channel delivers a `Float32List` (already a `List<double>`),
  /// so on the hot path this is effectively zero-copy.
  List<double> _decodeRawVertices(Object? raw) {
    if (raw is Float32List) {
      return raw;
    }
    return _asDoubleList(raw);
  }

  Map<String, double> _decodeBlendShapes(Object? raw) {
    if (raw is! Map) {
      return const <String, double>{};
    }
    final Map<String, double> result = <String, double>{};
    raw.forEach((Object? key, Object? value) {
      if (key is String && value is num) {
        result[key] = value.toDouble();
      }
    });
    return result;
  }

  /// Flat triangle index buffer (delivered as an `Int32List`).
  List<int> _decodeIntList(Object? raw) {
    if (raw is Int32List) {
      return raw;
    }
    if (raw is List) {
      return <int>[
        for (final Object? v in raw)
          if (v is num) v.toInt(),
      ];
    }
    return const <int>[];
  }

  List<double> _asDoubleList(Object? raw) {
    if (raw is List) {
      return <double>[
        for (final Object? v in raw)
          if (v is num) v.toDouble(),
      ];
    }
    return const <double>[];
  }

  /// Releases the stream controller. Call from the owning widget's dispose.
  Future<void> dispose() async {
    await stop();
    await _controller.close();
  }
}
