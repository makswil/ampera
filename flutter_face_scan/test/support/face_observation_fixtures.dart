import 'package:flutter_face_scan/features/face_capture/domain/constants/face_vertex_indices.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/euler_angles.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/face_blendshape.dart';
import 'package:flutter_face_scan/features/face_capture/domain/entities/face_observation.dart';
import 'package:vector_math/vector_math_64.dart';

/// Total ARKit face-mesh vertex count; fixtures allocate this many so every
/// symmetry-axis index is addressable.
const int kFaceVertexCount = 1220;

/// Builds a tracked [FaceObservation] whose symmetry-axis vertices lie exactly
/// on the line `origin + t * direction`, with the requested [eulerAngles].
///
/// `direction` need not be normalized. Non-axis vertices are left at the origin
/// (irrelevant to the axis fit).
FaceObservation observationOnLine({
  required EulerAngles eulerAngles,
  Vector3? direction,
  Vector3? origin,
  Duration timestamp = Duration.zero,
  Map<FaceBlendshape, double> blendshapes = const <FaceBlendshape, double>{},
  List<Vector2> axisScreenPoints = const <Vector2>[],
  List<int> triangleIndices = const <int>[],
  double distanceMeters = 0,
}) {
  final Vector3 dir = (direction ?? Vector3(0, -1, 0)).normalized();
  final Vector3 base = origin ?? Vector3.zero();

  // Flat [x0,y0,z0, …] buffer; non-axis vertices stay at the origin.
  final List<double> rawVertices = List<double>.filled(kFaceVertexCount * 3, 0);

  const List<int> axis = FaceSymmetryAxis.ordered;
  for (int i = 0; i < axis.length; i++) {
    // Spread samples 1cm apart along the line, centred on the origin.
    final double t = (i - axis.length / 2) * 0.01;
    final Vector3 v = base + dir * t;
    final int o = axis[i] * 3;
    rawVertices[o] = v.x;
    rawVertices[o + 1] = v.y;
    rawVertices[o + 2] = v.z;
  }

  return FaceObservation(
    timestamp: timestamp,
    isTracked: true,
    eulerAngles: eulerAngles,
    rawVertices: rawVertices,
    blendshapes: blendshapes,
    axisScreenPoints: axisScreenPoints,
    triangleIndices: triangleIndices,
    distanceMeters: distanceMeters,
  );
}

/// A straight vertical column of normalized 2D screen points centred at
/// [centerX], 0..1. Optional [tilt] (radians) rotates the column; [bend] adds a
/// quadratic curve to simulate a non-frontal (turned-head) projection.
List<Vector2> straightScreenAxis({
  double centerX = 0.5,
  double topY = 0.2,
  double bottomY = 0.8,
  int count = 20,
  double tilt = 0,
  double bend = 0,
}) {
  final List<Vector2> points = <Vector2>[];
  for (int i = 0; i < count; i++) {
    final double f = i / (count - 1); // 0..1
    final double y = topY + (bottomY - topY) * f;
    final double centred = f - 0.5;
    final double x = centerX + tilt * centred + bend * centred * centred;
    points.add(Vector2(x, y));
  }
  return points;
}
