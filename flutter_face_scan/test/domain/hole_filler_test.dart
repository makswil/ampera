// REDUNDANT(eye-fill): entire file obsolete — covers hole_filler.dart which is
// no longer used by the bake path (FaceHoleGeometry.eyeTriangles). Safe to delete.

import 'package:flutter_face_scan/features/face_capture/domain/v3/hole_filler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  // A unit quad (two triangles) — its four outer edges form one boundary loop.
  final List<int> quad = <int>[0, 1, 2, 0, 2, 3];
  final List<double> quadUvs = <double>[0, 0, 1, 0, 1, 1, 0, 1];
  final List<Vector3> quadVerts = <Vector3>[
    Vector3(0, 0, 0),
    Vector3(1, 0, 0),
    Vector3(1, 1, 0),
    Vector3(0, 1, 0),
  ];

  group('findBoundaryLoops', () {
    test('quad has a single 4-vertex boundary loop', () {
      final List<List<int>> loops = findBoundaryLoops(quad);
      expect(loops.length, 1);
      expect(loops.first.toSet(), <int>{0, 1, 2, 3});
    });

    test('closed mesh (no boundary) yields no loops', () {
      // Tetrahedron: every edge shared by two faces → watertight.
      final List<int> tetra = <int>[
        0, 1, 2, //
        0, 2, 3,
        0, 3, 1,
        1, 3, 2,
      ];
      expect(findBoundaryLoops(tetra), isEmpty);
    });
  });

  group('innerHoleLoops', () {
    test('drops the largest-UV-area loop (outer silhouette)', () {
      // Loop 0 spans the whole UV square (outer); loop 1 is a small interior hole.
      final List<List<int>> loops = <List<int>>[
        <int>[0, 1, 2, 3],
        <int>[4, 5, 6],
      ];
      final List<double> uvs = <double>[
        0, 0, 1, 0, 1, 1, 0, 1, // verts 0–3: full square
        0.4, 0.4, 0.5, 0.4, 0.5, 0.5, // verts 4–6: small patch
      ];
      final List<List<int>> inner = innerHoleLoops(loops, uvs);
      expect(inner.length, 1);
      expect(inner.first, <int>[4, 5, 6]);
    });

    test('a single loop (only outer boundary) yields nothing to cap', () {
      expect(innerHoleLoops(<List<int>>[<int>[0, 1, 2, 3]], quadUvs), isEmpty);
    });
  });

  group('cap geometry', () {
    test('fan-caps the loop from a centroid vertex', () {
      final List<List<int>> loops = findBoundaryLoops(quad);
      final CapGeometry cap = buildCapGeometry(loops, quadUvs, 4);

      // 4 rim edges → 4 fan triangles, all referencing centroid index 4.
      expect(cap.triangles.length, 4 * 3);
      for (int i = 2; i < cap.triangles.length; i += 3) {
        expect(cap.triangles[i], 4);
      }
      // Centroid UV = mean of the quad's UVs = (0.5, 0.5).
      expect(cap.uvs, <double>[0.5, 0.5]);
    });

    test('capVertices (flat) places the centroid at the loop mean', () {
      final List<List<int>> loops = findBoundaryLoops(quad);
      final List<Vector3> caps =
          capVertices(loops, quadVerts, depthFactor: 0);
      expect(caps.length, 1);
      expect(caps.first.x, closeTo(0.5, 1e-9));
      expect(caps.first.y, closeTo(0.5, 1e-9));
      expect(caps.first.z, closeTo(0, 1e-9));
    });

    test('capVertices with depth insets the centroid off the loop plane', () {
      final List<List<int>> loops = findBoundaryLoops(quad);
      final Vector3 cap =
          capVertices(loops, quadVerts, depthFactor: 0.5).first;
      // Stays centred in XY, but pushed along the plane normal (±Z).
      expect(cap.x, closeTo(0.5, 1e-9));
      expect(cap.y, closeTo(0.5, 1e-9));
      expect(cap.z.abs(), greaterThan(0));
    });
  });

  group('flattenHoleRims', () {
    test('projects rim verts onto a shared plane (same depth)', () {
      // Triangle hole whose verts sit at different Z — a recessed "socket".
      final List<Vector3> verts = <Vector3>[
        Vector3(0, 0, 0),
        Vector3(1, 0, 0.2),
        Vector3(0.5, 1, -0.1),
      ];
      flattenHoleRims(<List<int>>[
        <int>[0, 1, 2],
      ], verts);

      // After flatten, all three lie on one plane: (v1-v0)×(v2-v0) · (v-v0) ≈ 0.
      final Vector3 e1 = verts[1] - verts[0];
      final Vector3 e2 = verts[2] - verts[0];
      final Vector3 n = e1.cross(e2)..normalize();
      for (final Vector3 v in verts) {
        expect(n.dot(v - verts[0]).abs(), lessThan(1e-9));
      }
    });
  });
}
