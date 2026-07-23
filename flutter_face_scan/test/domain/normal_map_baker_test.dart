import 'package:flutter_face_scan/features/face_capture/domain/v3/normal_map_baker.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  test('bakeNormalMap fills covered UV texels with encoded normals', () {
    // One triangle covering the lower-left of a tiny atlas.
    final List<Vector3> verts = <Vector3>[
      Vector3(0, 0, 0),
      Vector3(1, 0, 0),
      Vector3(0, 1, 0),
    ];
    final List<Vector3> normals = <Vector3>[
      Vector3(0, 0, 1),
      Vector3(0, 0, 1),
      Vector3(0, 0, 1),
    ];
    final List<double> uvs = <double>[0, 0, 1, 0, 0, 1];
    final List<int> tris = <int>[0, 1, 2];

    final image = bakeNormalMap(
      vertices: verts,
      normals: normals,
      uvs: uvs,
      triangles: tris,
      size: 8,
    );

    // Centre of the triangle should be roughly +Z → RGB ~ (128,128,255).
    final p = image.getPixel(1, 1);
    expect(p.r.toInt(), closeTo(128, 2));
    expect(p.g.toInt(), closeTo(128, 2));
    expect(p.b.toInt(), closeTo(255, 2));
  });
}
