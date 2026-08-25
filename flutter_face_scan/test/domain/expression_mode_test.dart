import 'package:flutter_face_scan/features/face_capture/domain/entities/expression_mode.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('productLabel distinguishes 3D model from expression clip', () {
    expect(ExpressionMode.neutral.label, 'Pose');
    expect(ExpressionMode.smile.label, 'Expression');
    expect(ExpressionMode.neutral.productLabel, '3D model');
    expect(ExpressionMode.smile.productLabel, 'Expression clip');
  });
}
