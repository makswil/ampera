import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

import '../../domain/entities/euler_angles.dart';
import '../../domain/entities/face_blendshape.dart';
import '../../domain/entities/face_observation.dart';

/// Maps raw ARKit face-anchor primitives into a domain [FaceObservation].
///
/// Deliberately takes plain `vector_math` / Dart types (NOT `ARKitFaceAnchor`)
/// so it is unit-testable without the plugin or a device, and so the ARKit
/// dependency stays confined to [ArkitFaceTrackingService].
final class FaceAnchorMapper {
  const FaceAnchorMapper();

  FaceObservation map({
    required Duration timestamp,
    required Matrix4 transform,
    required List<double> rawVertices,
    required Map<String, double> blendShapes,
    Matrix4? cameraTransform,
    List<Vector2> axisScreenPoints = const <Vector2>[],
    List<int> triangleIndices = const <int>[],
    List<double> textureCoordinates = const <double>[],
  }) {
    return FaceObservation(
      timestamp: timestamp,
      isTracked: true,
      eulerAngles: eulerRelativeToCamera(transform, cameraTransform),
      rawVertices: rawVertices,
      blendshapes: _mapBlendshapes(blendShapes),
      axisScreenPoints: axisScreenPoints,
      transformStorage: transform.storage.toList(),
      triangleIndices: triangleIndices,
      textureCoordinates: textureCoordinates,
      distanceMeters: _distanceMeters(transform, cameraTransform),
    );
  }

  /// Straight-line distance (metres) from the camera to the face anchor origin,
  /// i.e. how far the face is from the lens. 0 when no camera transform (tests).
  double _distanceMeters(Matrix4 faceTransform, Matrix4? cameraTransform) {
    if (cameraTransform == null) {
      return 0;
    }
    final Matrix4 cameraInverse = Matrix4.copy(cameraTransform)..invert();
    final Matrix4 faceInCamera = cameraInverse.multiplied(faceTransform);
    return faceInCamera.getTranslation().length;
  }

  /// Head orientation **relative to the camera** (not world).
  ///
  /// ARKit's world heading is fixed at session start, so world-space yaw/pitch
  /// carry the user's initial-frame offset. Re-expressing the face pose in
  /// camera space (`inverse(camera) · face`) makes "looking at the lens" = 0°,
  /// independent of how the user was oriented at start. Falls back to the raw
  /// (world) transform when no camera transform is available (e.g. tests).
  EulerAngles eulerRelativeToCamera(
    Matrix4 faceTransform,
    Matrix4? cameraTransform,
  ) {
    if (cameraTransform == null) {
      return eulerFromTransform(faceTransform);
    }
    final Matrix4 cameraInverse = Matrix4.copy(cameraTransform)..invert();
    final Matrix4 faceInCamera = cameraInverse.multiplied(faceTransform);
    // Yaw/pitch (left/right, up/down) are reliable here. Roll (head tilt) is
    // NOT taken from this decomposition: the ARKit camera frame is landscape-
    // native, so in a portrait hold the roll axis is rotated ~90°. The pose
    // validator instead derives head tilt from the 2D screen-projected symmetry
    // axis, which is computed in the correct (portrait) orientation.
    return eulerFromTransform(faceInCamera);
  }

  /// Extracts Tait–Bryan angles (Y-X-Z) from the anchor's rotation.
  ///
  /// Sign/axis mapping is centralised here; if on-device calibration shows an
  /// inverted axis, this is the ONE place to flip it (logic & tests above stay
  /// untouched). Returned in [EulerAngles]' documented convention.
  EulerAngles eulerFromTransform(Matrix4 transform) {
    final Matrix3 r = transform.getRotation();

    // Row-major access via entry(row, col).
    final double sinPitch = -r.entry(2, 1);
    final double pitch = math.asin(sinPitch.clamp(-1.0, 1.0));

    double yaw;
    double roll;
    if (sinPitch.abs() < 0.9999) {
      yaw = math.atan2(r.entry(2, 0), r.entry(2, 2));
      roll = math.atan2(r.entry(0, 1), r.entry(1, 1));
    } else {
      // Gimbal lock fallback.
      yaw = math.atan2(-r.entry(0, 2), r.entry(0, 0));
      roll = 0.0;
    }

    return EulerAngles.fromRadians(yaw: yaw, pitch: pitch, roll: roll);
  }

  Map<FaceBlendshape, double> _mapBlendshapes(Map<String, double> raw) {
    final Map<FaceBlendshape, double> result = <FaceBlendshape, double>{};
    raw.forEach((String key, double value) {
      final FaceBlendshape? shape = FaceBlendshape.fromArkitKey(key);
      if (shape != null) {
        result[shape] = value;
      }
    });
    return result;
  }
}
