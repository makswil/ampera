import 'package:equatable/equatable.dart';
import 'package:vector_math/vector_math_64.dart';

import 'euler_angles.dart';
import 'face_blendshape.dart';

/// One immutable frame of TrueDepth face-tracking data, already mapped out of
/// any ARKit type. This is the **only** shape the domain/BLoC layer consumes —
/// it never sees `ARFaceAnchor` — which keeps all logic device-independent and
/// unit-testable.
///
/// Vertices are held as a flat `[x0,y0,z0, x1,y1,z1, …]` buffer ([rawVertices])
/// rather than `Vector3` objects. At 60 fps the full mesh is ~1220 points, so
/// materialising `Vector3`s every frame would allocate ~73k objects/sec and
/// stall the UI. Per-frame logic decodes only the handful it needs via
/// [verticesAt]; the full [vertices] list is materialised only at snapshot time.
final class FaceObservation extends Equatable {
  const FaceObservation({
    required this.timestamp,
    required this.isTracked,
    required this.eulerAngles,
    required this.rawVertices,
    required this.blendshapes,
    this.axisScreenPoints = const <Vector2>[],
    this.transformStorage = _identityStorage,
    this.triangleIndices = const <int>[],
    this.textureCoordinates = const <double>[],
    this.distanceMeters = 0,
  });

  /// An untracked frame (no face / lost tracking).
  const FaceObservation.lost(this.timestamp)
    : isTracked = false,
      eulerAngles = const EulerAngles.zero(),
      rawVertices = const <double>[],
      blendshapes = const <FaceBlendshape, double>{},
      axisScreenPoints = const <Vector2>[],
      transformStorage = _identityStorage,
      triangleIndices = const <int>[],
      textureCoordinates = const <double>[],
      distanceMeters = 0;

  /// Column-major identity matrix (default when no transform is supplied).
  static const List<double> _identityStorage = <double>[
    1, 0, 0, 0, //
    0, 1, 0, 0, //
    0, 0, 1, 0, //
    0, 0, 0, 1, //
  ];

  /// Frame capture time (monotonic, from the AR session).
  final Duration timestamp;

  /// Whether ARKit currently has a valid face anchor this frame.
  final bool isTracked;

  /// Head orientation this frame.
  final EulerAngles eulerAngles;

  /// Flat face-mesh vertex buffer in face-anchor local space (metres),
  /// `[x0,y0,z0, x1,y1,z1, …]`. Indexable (by vertex) via [verticesAt].
  final List<double> rawVertices;

  /// Tracked expression coefficients (0.0–1.0) for this frame.
  final Map<FaceBlendshape, double> blendshapes;

  /// Symmetry-axis vertices projected into **normalized screen space** (0..1,
  /// origin top-left). Empty when the backend doesn't provide them (e.g. unit
  /// tests). This is the 2D midline used to detect "facing the camera": it is
  /// straight on screen only when the head is frontal and upright, whereas the
  /// 3D axis always curves with the face.
  final List<Vector2> axisScreenPoints;

  /// Face-anchor → world transform, column-major 16 floats. Discarded by V1
  /// logic but persisted with snapshots so V3 can align the per-pose clouds.
  final List<double> transformStorage;

  /// Face-mesh triangle connectivity, flat `[a0,b0,c0, a1,b1,c1, …]` vertex
  /// indices (constant ARKit topology). Empty when the backend doesn't provide
  /// it; lets snapshots be written as proper surface meshes.
  final List<int> triangleIndices;

  /// Per-vertex UVs in ARKit's canonical face-texture atlas layout, flat
  /// `[u0,v0, u1,v1, …]` in [0,1] (constant topology). Empty when the backend
  /// doesn't provide them; defines the output-texture layout for UV baking.
  final List<double> textureCoordinates;

  /// Distance from the camera to the face (metres); 0 when unknown (tests).
  /// Used to keep the face at a constant size across captures.
  final double distanceMeters;

  /// Number of vertices in the mesh.
  int get vertexCount => rawVertices.length ~/ 3;

  /// Convenience view of [transformStorage] as a matrix.
  Matrix4 get transform => transformStorage.length == 16
      ? Matrix4.fromList(transformStorage)
      : Matrix4.identity();

  /// Materialises the full vertex list. Allocates — use only off the hot path
  /// (e.g. snapshot serialisation), not per frame.
  List<Vector3> get vertices {
    final List<Vector3> result = <Vector3>[];
    for (int i = 0; i + 2 < rawVertices.length; i += 3) {
      result.add(Vector3(rawVertices[i], rawVertices[i + 1], rawVertices[i + 2]));
    }
    return result;
  }

  /// Decodes only the vertices at [indices] (cheap; used per frame). Skips any
  /// out-of-range index defensively (the axis index table is marked uncertain).
  List<Vector3> verticesAt(List<int> indices) {
    final int count = vertexCount;
    final List<Vector3> result = <Vector3>[];
    for (final int index in indices) {
      if (index >= 0 && index < count) {
        final int o = index * 3;
        result.add(Vector3(rawVertices[o], rawVertices[o + 1], rawVertices[o + 2]));
      }
    }
    return result;
  }

  @override
  List<Object?> get props => <Object?>[
    timestamp,
    isTracked,
    eulerAngles,
    rawVertices,
    blendshapes,
    axisScreenPoints,
    transformStorage,
    triangleIndices,
    textureCoordinates,
    distanceMeters,
  ];
}
