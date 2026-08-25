import 'package:flutter_face_scan/features/face_capture/data/bake/expression_sequence_baker.dart';
import 'package:flutter_face_scan/features/face_capture/domain/constants/face_vertex_indices.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math_64.dart';

void main() {
  test('chin-up mouth falloff kills near rim, keeps far verts', () {
    final List<Vector3> verts = List<Vector3>.generate(
      1220,
      (_) => Vector3(1, 1, 1),
    );
    // Place mouth rim around origin; a "nostril" far above.
    for (final int i in FaceHoleGeometry.mouthOutline) {
      verts[i] = Vector3.zero();
    }
    const int far = 9; // nose tip index, not on mouth outline
    verts[far] = Vector3(0, 0.05, 0);

    final List<double> w = List<double>.filled(verts.length, 1);
    final List<double> out = expressionChinUpMouthFalloff(
      weights: w,
      verts: verts,
      innerRadius: 0.014,
      outerRadius: 0.030,
    );

    final int rim = FaceHoleGeometry.mouthOutline.first;
    expect(out[rim], 0);
    expect(out[far], 1);
  });
}
