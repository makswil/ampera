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
}
