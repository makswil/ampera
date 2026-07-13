import 'package:flutter_face_scan/features/face_capture/domain/v3/texture_projection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  group('barycentric', () {
    final Vector2 a = Vector2(0, 0);
    final Vector2 b = Vector2(4, 0);
    final Vector2 c = Vector2(0, 4);

    test('centroid is (1/3, 1/3, 1/3)', () {
      final Vector3? bc = barycentric(Vector2(4 / 3, 4 / 3), a, b, c);
      expect(bc, isNotNull);
      expect(bc!.x, closeTo(1 / 3, 1e-9));
      expect(bc.y, closeTo(1 / 3, 1e-9));
      expect(bc.z, closeTo(1 / 3, 1e-9));
    });

    test('point outside has a negative component', () {
      final Vector3 bc = barycentric(Vector2(3, 3), a, b, c)!;
      expect(bc.x < 0 || bc.y < 0 || bc.z < 0, isTrue);
    });

    test('degenerate triangle returns null', () {
      expect(barycentric(Vector2(1, 1), a, a, a), isNull);
    });
  });

  group('PoseProjection', () {
    test('identity projection maps origin to image centre', () {
      final PoseProjection proj = PoseProjection(
        width: 100,
        height: 200,
        viewMatrix: Matrix4.identity(),
        projectionMatrix: Matrix4.identity(),
        faceTransform: Matrix4.identity(),
      );
      final Vector2? p = proj.projectPixel(Vector3.zero());
      expect(p, isNotNull);
      expect(p!.x, closeTo(50, 1e-9));
      expect(p.y, closeTo(100, 1e-9)); // y flipped, centre stays centre
    });

    test('positive NDC y lands in the upper half (smaller pixel y)', () {
      final PoseProjection proj = PoseProjection(
        width: 100,
        height: 200,
        viewMatrix: Matrix4.identity(),
        projectionMatrix: Matrix4.identity(),
        faceTransform: Matrix4.identity(),
      );
      final Vector2 p = proj.projectPixel(Vector3(0, 0.5, 0))!;
      expect(p.y < 100, isTrue);
    });

    test('point behind the camera (w <= 0) returns null', () {
      final Matrix4 projection = Matrix4.identity()..setEntry(3, 3, -1);
      final PoseProjection proj = PoseProjection(
        width: 100,
        height: 200,
        viewMatrix: Matrix4.identity(),
        projectionMatrix: projection,
        faceTransform: Matrix4.identity(),
      );
      expect(proj.projectPixel(Vector3.zero()), isNull);
    });
  });
}
