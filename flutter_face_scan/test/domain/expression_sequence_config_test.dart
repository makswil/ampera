import 'package:flutter_face_scan/features/face_capture/domain/constants/expression_sequence_config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('expression sequence defaults match the agreed plan', () {
    expect(ExpressionSequenceConfig.readyHold, const Duration(milliseconds: 250));
    expect(ExpressionSequenceConfig.countdown, const Duration(seconds: 3));
    expect(ExpressionSequenceConfig.onsetLookback, const Duration(seconds: 1));
    expect(ExpressionSequenceConfig.recordDurationMin, const Duration(seconds: 3));
    expect(ExpressionSequenceConfig.recordDurationMax, const Duration(seconds: 10));
    expect(ExpressionSequenceConfig.mimicChangeEpsilon, 0.08);
    expect(ExpressionSequenceConfig.mimicStableFor, const Duration(milliseconds: 800));
    expect(ExpressionSequenceConfig.onsetDelta, 0.15);
    expect(ExpressionSequenceConfig.onsetAbsolute, 0.22);
    expect(ExpressionSequenceConfig.targetFps, 20);
    expect(ExpressionSequenceConfig.supportHold, const Duration(milliseconds: 1200));
    expect(ExpressionSequenceConfig.supportPoses.length, 3);
  });
}
