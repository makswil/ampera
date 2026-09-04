import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_face_scan/features/face_capture/application/model_generate_service.dart';
import 'package:flutter_face_scan/features/face_capture/application/session_white_balance.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('prepareExpressionSupportMlWb matches stills to the first clip JPEG',
      () async {
    final Directory dir = await Directory.systemTemp.createTemp('expr_mlwb');
    addTearDown(() => dir.delete(recursive: true));
    await Directory('${dir.path}/support').create();
    await File('${dir.path}/frame_0004.jpg').writeAsBytes(const <int>[1, 2, 3]);
    await File('${dir.path}/support/right40.jpg').writeAsBytes(const <int>[4]);
    await File('${dir.path}/support/left40.jpg').writeAsBytes(const <int>[5]);
    await File('${dir.path}/sequence.json').writeAsString(
      '{"frames":[{"jpg":"frame_0004.jpg"}]}',
    );

    late List<Uint8List> seen;
    final ({Map<String, Uint8List>? overrides, String note}) out =
        await prepareExpressionSupportMlWb(
      manifestPath: '${dir.path}/sequence.json',
      correct: ({
        required List<Uint8List> jpegs,
        required bool matchFrontal,
        required double targetKelvin,
      }) async {
        seen = jpegs;
        expect(matchFrontal, isTrue);
        return WhiteBalanceCorrection(
          ok: true,
          jpegs: <Uint8List>[
            Uint8List.fromList(const <int>[9]),
            Uint8List.fromList(const <int>[10]),
            Uint8List.fromList(const <int>[11]),
          ],
          targetKelvin: 4200,
        );
      },
    );

    expect(seen.length, 3);
    expect(seen[0], Uint8List.fromList(const <int>[1, 2, 3]));
    expect(out.overrides, isNotNull);
    expect(out.overrides!['right40.jpg'], Uint8List.fromList(const <int>[10]));
    expect(out.overrides!['left40.jpg'], Uint8List.fromList(const <int>[11]));
    expect(out.overrides!.containsKey('frame_0004.jpg'), isFalse);
    expect(out.note, contains('2 stills'));
  });
}
