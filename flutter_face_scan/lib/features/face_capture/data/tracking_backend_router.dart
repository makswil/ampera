import 'dart:async';
import 'dart:typed_data';

import '../domain/constants/capture_defaults.dart';
import '../domain/entities/face_observation.dart';
import '../domain/entities/still_capture.dart';
import '../domain/services/face_tracking_service.dart';
import 'arkit_face_tracking_service.dart';
import 'rear_face_tracking_service.dart';

enum TrackingBackend { front, rear }

/// Switches the [CaptureBloc] observation source between front TrueDepth and
/// rear Vision without rebuilding the bloc.
final class TrackingBackendRouter implements FaceTrackingService {
  TrackingBackendRouter({
    required this.front,
    required this.rear,
  }) : _backend = TrackingBackend.front;

  final ArkitFaceTrackingService front;
  final RearFaceTrackingService rear;

  TrackingBackend _backend;
  final StreamController<FaceObservation> _out =
      StreamController<FaceObservation>.broadcast();
  StreamSubscription<FaceObservation>? _sub;
  bool _running = false;

  TrackingBackend get backend => _backend;
  bool get isRear => _backend == TrackingBackend.rear;

  FaceTrackingService get _active =>
      _backend == TrackingBackend.rear ? rear : front;

  @override
  Stream<FaceObservation> get observations => _out.stream;

  /// Stop current backend, select [next], do not auto-start.
  Future<void> select(TrackingBackend next) async {
    if (_backend == next) {
      return;
    }
    await stop();
    _backend = next;
  }

  @override
  Future<void> start() async {
    if (_running) {
      return;
    }
    _running = true;
    try {
      await _sub?.cancel();
      _sub = _active.observations.listen(
        _out.add,
        onError: _out.addError,
      );
      await _active.start();
    } on Object {
      _running = false;
      await _sub?.cancel();
      _sub = null;
      rethrow;
    }
  }

  @override
  Future<void> stop() async {
    if (!_running) {
      // Still stop the underlying session if it was started outside the router
      // (e.g. idle front preview before the first routed start).
      await front.stop();
      await rear.stop();
      return;
    }
    _running = false;
    await _sub?.cancel();
    _sub = null;
    await front.stop();
    await rear.stop();
  }

  Future<void> setRearPreferVideo(bool value) => rear.setPreferVideo(value);

  Future<void> beginRearHarvest({bool lockAeAwb = true}) =>
      rear.beginHarvest(lockAeAwb: lockAeAwb);

  Future<StillCapture?> takeRearHarvestedFrame() => rear.takeHarvestedFrame();

  Future<StillCapture?> captureStill({
    bool hiRes = false,
    bool lockAeAwb = true,
    bool preferHarvestedVideoFrame = false,
    bool currentFrameOnly = false,
  }) async {
    if (_backend == TrackingBackend.rear) {
      if (preferHarvestedVideoFrame) {
        final StillCapture? harvested = await rear.takeHarvestedFrame();
        if (harvested != null && harvested.bytes.isNotEmpty) {
          return harvested;
        }
      }
      return rear.captureStill(lockAeAwb: lockAeAwb);
    }
    // Front: same ARKit session as expression clip (never AVCapture hi-res here).
    return front.captureStill(
      hiRes: hiRes,
      lockAeAwb: lockAeAwb,
      currentFrameOnly: currentFrameOnly,
    );
  }

  Future<Uint8List?> previewFreeze() {
    if (_backend == TrackingBackend.rear) {
      return rear.previewFreeze();
    }
    return front.previewFreeze();
  }

  Future<void> setOverlay({
    required bool showMesh,
    required List<int> axisIndices,
  }) {
    return front.setOverlay(showMesh: showMesh, axisIndices: axisIndices);
  }

  Future<void> shareFiles(List<String> paths) => front.shareFiles(paths);

  Future<void> previewFile(String path) => front.previewFile(path);

  Future<void> dismissPresented() => front.dismissPresented();

  Future<void> openAppSettings() => front.openAppSettings();

  Future<Map<String, Object?>> rearCapabilities() => rear.capabilities();

  bool? get hiResCapture =>
      _backend == TrackingBackend.rear ? true : front.hiResCapture;

  int get captureWidth =>
      _backend == TrackingBackend.rear ? rear.captureWidth : front.captureWidth;

  int get captureHeight => _backend == TrackingBackend.rear
      ? rear.captureHeight
      : front.captureHeight;

  int get photoWidth =>
      _backend == TrackingBackend.rear ? rear.photoWidth : front.photoWidth;

  int get photoHeight =>
      _backend == TrackingBackend.rear ? rear.photoHeight : front.photoHeight;

  Future<WhiteBalanceResult?> correctWhiteBalance({
    required List<Uint8List> jpegs,
    bool matchFrontal = false,
    double targetKelvin = CaptureDefaults.neutralKelvin,
  }) {
    return front.correctWhiteBalance(
      jpegs: jpegs,
      matchFrontal: matchFrontal,
      targetKelvin: targetKelvin,
    );
  }

  Future<void> dispose() async {
    await stop();
    await front.dispose();
    await rear.dispose();
    await _out.close();
  }
}
