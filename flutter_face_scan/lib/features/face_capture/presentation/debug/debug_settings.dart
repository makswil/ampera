import 'package:flutter/foundation.dart';

import 'capture_debug_hud.dart';

/// Whether the in-app tools button (⚙ → HUD/mesh toggles + manage scans) is
/// shown. Kept as a single switch so it can be turned off for production by
/// setting this to `false` (or `bool.fromEnvironment` if you prefer a define).
const bool kShowDevMenu = true;

/// Runtime-toggleable debug flags, so the calibration HUD / mesh overlay can be
/// switched on the device without a rebuild. Seeded from the compile-time
/// `--dart-define` flags so those still act as defaults.
class DebugSettings extends ChangeNotifier {
  DebugSettings({
    bool? showHud,
    bool? showMesh,
    bool? fillHoles,
    int? textureSize,
  }) : _showHud = showHud ?? kCaptureDebugHud,
       _showMesh = showMesh ?? kFaceMeshOverlay,
       _fillHoles = fillHoles ?? true,
       _textureSize = textureSize ?? 2048;

  /// Selectable bake texture resolutions (px). Higher only adds real detail up
  /// to the source photo resolution — above that it just upsamples.
  static const List<int> textureSizeOptions = <int>[1024, 2048, 4096];

  bool _showHud;
  bool _showMesh;
  bool _fillHoles;
  int _textureSize;

  bool get showHud => _showHud;
  bool get showMesh => _showMesh;

  /// Whether the open eye/mouth holes are capped + textured (on) or left as
  /// holes (off) in the baked model. Default on.
  bool get fillHoles => _fillHoles;

  set showHud(bool value) {
    if (value != _showHud) {
      _showHud = value;
      notifyListeners();
    }
  }

  set showMesh(bool value) {
    if (value != _showMesh) {
      _showMesh = value;
      notifyListeners();
    }
  }

  set fillHoles(bool value) {
    if (value != _fillHoles) {
      _fillHoles = value;
      notifyListeners();
    }
  }

  /// Bake texture resolution (px, square).
  int get textureSize => _textureSize;

  set textureSize(int value) {
    if (value != _textureSize) {
      _textureSize = value;
      notifyListeners();
    }
  }
}
