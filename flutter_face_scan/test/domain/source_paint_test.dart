import 'package:flutter_face_scan/features/face_capture/domain/v3/source_paint.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SourcePaintMap', () {
    test('tryParse clamps labels and rejects empty', () {
      expect(SourcePaintMap.tryParse(<String, Object?>{}), isNull);
      final SourcePaintMap? map = SourcePaintMap.tryParse(<String, Object?>{
        'epoch': SourcePaintMap.epoch,
        'labels': <Object?>[0, 1, 9, -1],
      });
      expect(map, isNotNull);
      expect(map!.labels, <int>[0, 1, 4, 0]);
    });

    test('toJson includes compact clip/left/right/chin index lists', () {
      final SourcePaintMap map = SourcePaintMap(<int>[
        0,
        SourcePaintLabel.clip.index,
        SourcePaintLabel.left.index,
      ]);
      expect(map.indicesFor(SourcePaintLabel.clip), <int>[1]);
      expect(map.toJson()['clip'], <int>[1]);
      expect(map.compactIndexText(), contains('clip: 1'));
    });

    test('tryParse drops stale epoch', () {
      expect(
        SourcePaintMap.tryParse(<String, Object?>{
          'epoch': 0,
          'labels': <int>[1],
        }),
        isNull,
      );
    });

    test('expressionDirForObj only matches expression/baked OBJ', () {
      expect(
        SourcePaintMap.expressionDirForObj(
          '/sessions/s1/expression/baked/frame_0000.obj',
        )?.path,
        '/sessions/s1/expression',
      );
      expect(
        SourcePaintMap.fileForObj(
          '/sessions/s1/expression/baked/frame_0000.obj',
        )?.path,
        '/sessions/s1/expression/source_paint.json',
      );
      expect(
        SourcePaintMap.expressionDirForObj('/sessions/s1/baked.obj'),
        isNull,
      );
    });
  });

  group('applySourcePaintToWeights', () {
    test('auto leaves exclusive pick', () {
      final List<double> f = <double>[1, 0];
      final List<double> l = <double>[0, 1];
      applySourcePaintToWeights(
        labels: <int>[0, 0],
        wFrontal: f,
        wLeft: l,
      );
      expect(f, <double>[1, 0]);
      expect(l, <double>[0, 1]);
    });

    test('clip forces frontal even where exclusive picked left', () {
      final List<double> f = <double>[0];
      final List<double> l = <double>[1];
      applySourcePaintToWeights(
        labels: <int>[SourcePaintLabel.clip.index],
        wFrontal: f,
        wLeft: l,
      );
      expect(f, <double>[1]);
      expect(l, <double>[0]);
    });

    test('left forces support; missing pose is a no-op', () {
      final List<double> f = <double>[1, 1];
      final List<double> l = <double>[0, 0];
      applySourcePaintToWeights(
        labels: <int>[
          SourcePaintLabel.left.index,
          SourcePaintLabel.right.index,
        ],
        wFrontal: f,
        wLeft: l,
      );
      expect(f[0], 0);
      expect(l[0], 1);
      expect(f[1], 1);
      expect(l[1], 0);
    });
  });

  group('expressionDefaultSourceLabels', () {
    test('stamps clip then L/R on the hardcoded boundary verts', () {
      final List<int> labels = expressionDefaultSourceLabels(1220);
      expect(labels.length, 1220);
      expect(labels[474], SourcePaintLabel.clip.index);
      expect(labels[475], SourcePaintLabel.left.index);
      expect(labels[890], SourcePaintLabel.clip.index);
      expect(labels[891], SourcePaintLabel.right.index);
      expect(labels[1046], SourcePaintLabel.right.index);
      expect(labels[0], SourcePaintLabel.auto.index);
    });
  });
}
