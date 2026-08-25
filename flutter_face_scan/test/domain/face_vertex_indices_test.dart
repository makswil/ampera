import 'package:flutter_face_scan/features/face_capture/domain/constants/face_vertex_indices.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('FaceSymmetryAxis', () {
    test('ordered axis = upper + lower segments concatenated', () {
      expect(
        FaceSymmetryAxis.ordered,
        equals(<int>[
          ...FaceSymmetryAxis.foreheadToUpperLip,
          ...FaceSymmetryAxis.lowerLipToChin,
        ]),
      );
    });

    test('mouth gap sits between upper-lip (24) and lower-lip (25)', () {
      expect(FaceSymmetryAxis.foreheadToUpperLip.last, 24);
      expect(FaceSymmetryAxis.lowerLipToChin.first, 25);
    });

    test('endpoints are forehead (20) and chin (1047)', () {
      expect(FaceSymmetryAxis.foreheadVertex, 20);
      expect(FaceSymmetryAxis.chinVertex, 1047);
    });

    test('no duplicate indices in the axis', () {
      final Set<int> unique = FaceSymmetryAxis.ordered.toSet();
      expect(unique.length, FaceSymmetryAxis.ordered.length);
    });
  });

  group('FaceHoleGeometry', () {
    test('each eye has 22 triangles', () {
      expect(FaceHoleGeometry.leftEyeTriangles.length, 22 * 3);
      expect(FaceHoleGeometry.rightEyeTriangles.length, 22 * 3);
      expect(FaceHoleGeometry.eyeTriangles.length, 44 * 3);
    });

    test('left eye indices stay in 1085–1108', () {
      for (final int i in FaceHoleGeometry.leftEyeTriangles) {
        expect(i, inInclusiveRange(1085, 1108));
      }
    });

    test('right eye indices stay in 1061–1084', () {
      for (final int i in FaceHoleGeometry.rightEyeTriangles) {
        expect(i, inInclusiveRange(1061, 1084));
      }
    });

    test('mouth has 34 triangles', () {
      expect(FaceHoleGeometry.mouthTriangles.length, 34 * 3);
    });

    test('mouth outline is a closed loop starting at 823', () {
      expect(FaceHoleGeometry.mouthOutline.first, 823);
      expect(FaceHoleGeometry.mouthOutline.last, 823);
      expect(FaceHoleGeometry.mouthOutline.length, 37);
    });

    test('every mouth triangle vertex lies on the mouth outline', () {
      final Set<int> rim = FaceHoleGeometry.mouthOutline.toSet();
      for (final int i in FaceHoleGeometry.mouthTriangles) {
        expect(rim, contains(i));
      }
    });

    test('holeTriangles is eyes then mouth', () {
      expect(
        FaceHoleGeometry.holeTriangles,
        equals(<int>[
          ...FaceHoleGeometry.eyeTriangles,
          ...FaceHoleGeometry.mouthTriangles,
        ]),
      );
    });

    test('eyeVertexIndices cover both eye ranges', () {
      expect(FaceHoleGeometry.eyeVertexIndices.length, 48);
      expect(FaceHoleGeometry.eyeVertexIndices, containsAll(<int>[1085, 1108]));
      expect(FaceHoleGeometry.eyeVertexIndices, containsAll(<int>[1061, 1084]));
    });

    test('mouthVertexIndices match outline (closed loop unique)', () {
      expect(
        FaceHoleGeometry.mouthVertexIndices,
        FaceHoleGeometry.mouthOutline.toSet(),
      );
    });
  });
}
