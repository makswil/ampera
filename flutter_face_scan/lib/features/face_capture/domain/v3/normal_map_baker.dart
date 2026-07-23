import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:vector_math/vector_math_64.dart';

import 'texture_projection.dart';

/// Bakes an **object-space normal map** into the ARKit UV atlas by rasterizing
/// mesh triangles in UV space and interpolating per-vertex normals.
///
/// TrueDepth's usable "depth geometry" for face tracking is the face mesh
/// itself (sensor depth frames are often unavailable under
/// `ARFaceTrackingConfiguration`). Encoding face-local normals as RGB
/// (`n·0.5+0.5`) gives renderers a bump/normal map without changing the mesh.
///
/// Empty / uncovered texels stay flat-blue `(0.5, 0.5, 1)` (= +Z).
img.Image bakeNormalMap({
  required List<Vector3> vertices,
  required List<Vector3> normals,
  required List<double> uvs,
  required List<int> triangles,
  required int size,
}) {
  final img.Image out = img.Image(width: size, height: size);
  // Default: pointing "out" in object space (+Z after encode).
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      out.setPixelRgba(x, y, 128, 128, 255, 255);
    }
  }

  final int vertCount = vertices.length;
  for (int i = 0; i + 2 < triangles.length; i += 3) {
    final int a = triangles[i];
    final int b = triangles[i + 1];
    final int c = triangles[i + 2];
    if (a >= vertCount ||
        b >= vertCount ||
        c >= vertCount ||
        a * 2 + 1 >= uvs.length ||
        b * 2 + 1 >= uvs.length ||
        c * 2 + 1 >= uvs.length) {
      continue;
    }
    final Vector2 uvA = Vector2(uvs[a * 2] * size, uvs[a * 2 + 1] * size);
    final Vector2 uvB = Vector2(uvs[b * 2] * size, uvs[b * 2 + 1] * size);
    final Vector2 uvC = Vector2(uvs[c * 2] * size, uvs[c * 2 + 1] * size);

    final int minX = math.max(0, _floor3(uvA.x, uvB.x, uvC.x));
    final int maxX = math.min(size - 1, _ceil3(uvA.x, uvB.x, uvC.x));
    final int minY = math.max(0, _floor3(uvA.y, uvB.y, uvC.y));
    final int maxY = math.min(size - 1, _ceil3(uvA.y, uvB.y, uvC.y));
    if (minX > maxX || minY > maxY) {
      continue;
    }

    final Vector3 nA = a < normals.length ? normals[a] : Vector3(0, 0, 1);
    final Vector3 nB = b < normals.length ? normals[b] : Vector3(0, 0, 1);
    final Vector3 nC = c < normals.length ? normals[c] : Vector3(0, 0, 1);

    for (int py = minY; py <= maxY; py++) {
      for (int px = minX; px <= maxX; px++) {
        final Vector3? bc =
            barycentric(Vector2(px + 0.5, py + 0.5), uvA, uvB, uvC);
        if (bc == null || bc.x < 0 || bc.y < 0 || bc.z < 0) {
          continue;
        }
        final Vector3 n = (nA * bc.x + nB * bc.y + nC * bc.z);
        if (n.length2 > 0) {
          n.normalize();
        } else {
          n.setValues(0, 0, 1);
        }
        // Object-space normal → RGB.
        final int r = ((n.x * 0.5 + 0.5) * 255).round().clamp(0, 255);
        final int g = ((n.y * 0.5 + 0.5) * 255).round().clamp(0, 255);
        final int bCh = ((n.z * 0.5 + 0.5) * 255).round().clamp(0, 255);
        out.setPixelRgba(px, py, r, g, bCh, 255);
      }
    }
  }
  return out;
}

int _floor3(double a, double b, double c) =>
    math.min(a, math.min(b, c)).floor();

int _ceil3(double a, double b, double c) =>
    math.max(a, math.max(b, c)).ceil();
