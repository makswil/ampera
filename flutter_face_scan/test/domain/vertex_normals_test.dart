import 'package:flutter_face_scan/features/face_capture/domain/v3/vertex_normals.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  test('flat CCW quad in XY plane yields +Z normals everywhere', () {
    final List<Vector3> verts = <Vector3>[
      Vector3(0, 0, 0),
      Vector3(1, 0, 0),
      Vector3(1, 1, 0),
      Vector3(0, 1, 0),
    ];
    final List<int> tris = <int>[0, 1, 2, 0, 2, 3]; // CCW → +Z

    final List<Vector3> normals = computeVertexNormals(verts, tris);

    expect(normals.length, 4);
    for (final Vector3 n in normals) {
      expect(n.x, closeTo(0, 1e-9));
      expect(n.y, closeTo(0, 1e-9));
      expect(n.z, closeTo(1, 1e-9));
    }
  });

  test('vertex touched by no face gets a zero normal', () {
    final List<Vector3> verts = <Vector3>[
      Vector3(0, 0, 0),
      Vector3(1, 0, 0),
      Vector3(0, 1, 0),
      Vector3(5, 5, 5), // unused
    ];
    final List<int> tris = <int>[0, 1, 2];

    final List<Vector3> normals = computeVertexNormals(verts, tris);

    expect(normals[3].length2, 0);
  });

  test('out-of-range triangle indices are skipped, not thrown', () {
    final List<Vector3> verts = <Vector3>[Vector3.zero()];
    expect(
      () => computeVertexNormals(verts, <int>[0, 5, 9]),
      returnsNormally,
    );
  });
}
