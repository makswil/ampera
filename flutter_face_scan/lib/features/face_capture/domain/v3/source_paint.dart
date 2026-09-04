import 'dart:convert';
import 'dart:io';

import '../constants/face_vertex_indices.dart';

/// Per-vertex albedo source painted in the Dev 3D viewer.
///
/// [auto] leaves the bake's `n·v` exclusive pick. Other values force that
/// pose when it exists. Index-aligned with ARKit's 1220 verts. Does not
/// change 4-pose bake.
enum SourcePaintLabel {
  auto,
  clip,
  left,
  right,
  chin,
}

/// Flat label list + JSON IO for `expression/source_paint.json`.
final class SourcePaintMap {
  const SourcePaintMap(this.labels);

  /// 0 = auto, 1 = clip, 2 = left, 3 = right, 4 = chin.
  final List<int> labels;

  static const int version = 1;

  /// Bump when bake source logic changes. On-disk paint with a different
  /// epoch is deleted so a Generate tests the new logic, not an old mask.
  static const int epoch = 4;

  /// Relative name under the expression folder (survives baked/ delete).
  static const String fileName = 'source_paint.json';

  bool get isEmpty => labels.every((int v) => v == SourcePaintLabel.auto.index);

  static SourcePaintMap? tryParse(Object? decoded) {
    if (decoded is! Map) {
      return null;
    }
    final Object? raw = decoded['labels'];
    if (raw is! List) {
      return null;
    }
    final List<int> labels = <int>[
      for (final Object? e in raw)
        if (e is num) e.toInt().clamp(0, SourcePaintLabel.values.length - 1),
    ];
    if (labels.isEmpty) {
      return null;
    }
    final int fileEpoch = (decoded['epoch'] as num?)?.toInt() ?? 0;
    if (fileEpoch != epoch) {
      return null;
    }
    return SourcePaintMap(labels);
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'version': version,
        'epoch': epoch,
        'vertexCount': labels.length,
        'labels': labels,
        'clip': indicesFor(SourcePaintLabel.clip),
        'left': indicesFor(SourcePaintLabel.left),
        'right': indicesFor(SourcePaintLabel.right),
        'chin': indicesFor(SourcePaintLabel.chin),
      };

  List<int> indicesFor(SourcePaintLabel label) => <int>[
        for (int i = 0; i < labels.length; i++)
          if (labels[i] == label.index) i,
      ];

  /// Paste-able list for chat: `clip: 12, 15` …
  String compactIndexText() {
    final StringBuffer out = StringBuffer(
      '# source_paint epoch=$epoch n=${labels.length}\n',
    );
    for (final SourcePaintLabel label in SourcePaintLabel.values) {
      if (label == SourcePaintLabel.auto) {
        continue;
      }
      final List<int> ids = indicesFor(label);
      out.writeln('${label.name}: ${ids.join(', ')}');
    }
    return out.toString();
  }

  static Future<SourcePaintMap?> load(File file) async {
    if (!file.existsSync()) {
      return null;
    }
    try {
      final SourcePaintMap? parsed =
          tryParse(jsonDecode(await file.readAsString()));
      if (parsed == null) {
        try {
          await file.delete();
        } on Object {
          // Stale or corrupt paint — Generate without a mask.
        }
      }
      return parsed;
    } on Object {
      try {
        await file.delete();
      } on Object {
        // Ignore.
      }
      return null;
    }
  }

  Future<void> save(File file) async {
    await file.writeAsString(
      const JsonEncoder.withIndent('  ').convert(toJson()),
      flush: true,
    );
  }

  /// Expression folder for a bake OBJ (`…/expression/baked/frame_0000.obj`).
  static Directory? expressionDirForObj(String objPath) {
    final Directory baked = File(objPath).parent;
    if (!baked.path.endsWith('/baked') && !baked.path.endsWith(r'\baked')) {
      return null;
    }
    final Directory expr = baked.parent;
    final String name = expr.uri.pathSegments.isEmpty
        ? expr.path
        : expr.uri.pathSegments.lastWhere(
            (String s) => s.isNotEmpty,
            orElse: () => '',
          );
    if (name != 'expression') {
      return null;
    }
    return expr;
  }

  static File? fileForObj(String objPath) {
    final Directory? expr = expressionDirForObj(objPath);
    if (expr == null) {
      return null;
    }
    return File('${expr.path}/$fileName');
  }
}

/// Overwrites exclusive bake weights for painted verts. Missing poses skip
/// (label stays as exclusive pick). Mutates the weight lists in place.
void applySourcePaintToWeights({
  required List<int> labels,
  required List<double> wFrontal,
  List<double>? wLeft,
  List<double>? wRight,
  List<double>? wChin,
}) {
  final int n = wFrontal.length;
  for (int i = 0; i < n && i < labels.length; i++) {
    final int label = labels[i];
    if (label == SourcePaintLabel.auto.index) {
      continue;
    }
    if (label == SourcePaintLabel.left.index && wLeft == null) {
      continue;
    }
    if (label == SourcePaintLabel.right.index && wRight == null) {
      continue;
    }
    if (label == SourcePaintLabel.chin.index && wChin == null) {
      continue;
    }
    wFrontal[i] = label == SourcePaintLabel.clip.index ? 1 : 0;
    if (wLeft != null && i < wLeft.length) {
      wLeft[i] = label == SourcePaintLabel.left.index ? 1 : 0;
    }
    if (wRight != null && i < wRight.length) {
      wRight[i] = label == SourcePaintLabel.right.index ? 1 : 0;
    }
    if (wChin != null && i < wChin.length) {
      wChin[i] = label == SourcePaintLabel.chin.index ? 1 : 0;
    }
  }
}

/// Hardcoded clip / L / R boundary for expression bake.
///
/// Exact verts only — neighboring clip and L/R verts are allowed. L/R is
/// stamped after clip so an overlap (if any) stays on the support still.
List<int> expressionDefaultSourceLabels(int vertexCount) {
  final List<int> out = List<int>.filled(
    vertexCount,
    SourcePaintLabel.auto.index,
  );
  void stamp(List<int> ids, SourcePaintLabel label) {
    for (final int i in ids) {
      if (i >= 0 && i < vertexCount) {
        out[i] = label.index;
      }
    }
  }

  stamp(FaceHoleGeometry.browVertexIndices, SourcePaintLabel.clip);
  stamp(FaceHoleGeometry.browLeftVertexIndices, SourcePaintLabel.left);
  stamp(FaceHoleGeometry.browRightVertexIndices, SourcePaintLabel.right);
  return out;
}
