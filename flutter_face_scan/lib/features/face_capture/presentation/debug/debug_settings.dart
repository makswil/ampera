import 'package:flutter/foundation.dart';

import '../../domain/value_objects/pose_tolerance.dart';

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
    bool? hiResPhoto,
    bool? lockAeAwb,
    bool? chinUpLowerFace,
    bool? viewDependent,
    bool? viewBestOnly,
    bool? dartColorGain,
    bool? bakeNormalMap,
    double? targetDistanceMeters,
    bool? mlWb,
    bool? mlWbMatchFrontal,
  }) : _showHud = showHud ?? true,
       _showMesh = showMesh ?? true,
       _fillHoles = fillHoles ?? true,
       _hiResPhoto = hiResPhoto ?? true,
       _lockAeAwb = lockAeAwb ?? true,
       _chinUpLowerFace = chinUpLowerFace ?? true,
       _viewDependent = viewDependent ?? true,
       _viewBestOnly = viewBestOnly ?? false,
       _dartColorGain = dartColorGain ?? false,
       _bakeNormalMap = bakeNormalMap ?? false,
       _targetDistanceMeters = (targetDistanceMeters ??
               PoseTolerance.kDefaultTargetDistanceMeters)
           .clamp(
             PoseTolerance.kMinTargetDistanceMeters,
             PoseTolerance.kMaxTargetDistanceMeters,
           ),
       _mlWb = mlWb ?? true,
       _mlWbMatchFrontal = mlWbMatchFrontal ?? false;

  bool _showHud;
  bool _showMesh;
  bool _fillHoles;
  bool _hiResPhoto;
  bool _lockAeAwb;
  bool _chinUpLowerFace;
  bool _viewDependent;
  bool _viewBestOnly;
  bool _dartColorGain;
  bool _bakeNormalMap;
  double _targetDistanceMeters;
  bool _mlWb;
  bool _mlWbMatchFrontal;

  bool get showHud => _showHud;
  bool get showMesh => _showMesh;

  /// Whether the open eye/mouth holes are capped + textured (on) or left as
  /// holes (off) in the baked model. Default on.
  bool get fillHoles => _fillHoles;

  /// Texture source: false = ARKit video frame (stable), true = AVCapture hi-res
  /// still. Default on.
  bool get hiResPhoto => _hiResPhoto;

  /// Only for AVCapture hi-res: after the first pose photo settles AE/AWB, lock
  /// ISO/shutter/WB gains and reuse for later poses (less exposure flicker).
  /// Default on. New scan clears the lock.
  bool get lockAeAwb => _lockAeAwb;

  /// Whether the lower/under face (chin, jaw underside) is sourced from the
  /// chin-up pose (on) or left on the frontal source (off). Default on. Turn off
  /// to A/B or if the chin-up blend ghosts.
  bool get chinUpLowerFace => _chinUpLowerFace;

  /// View-dependent (normal-based, `n·v`) texture blend (on) vs. the static
  /// region tables (off). Default on. When on, each pose contributes per surface
  /// point by how head-on it saw it, gated by per-pose spatial guards.
  bool get viewDependent => _viewDependent;

  /// Only relevant when [viewDependent] is on: `true` = best-only (single
  /// highest-`n·v` pose per texel → sharp; hard seams possible).
  /// `false` (default) = weighted blend (smoother colour). Re-bake to apply.
  bool get viewBestOnly => _viewBestOnly;

  /// Only when [viewDependent] is on: Dart `poseGain` — match each pose's mean
  /// RGB to frontal over their overlap. Default off (A/B with ml-wb). Re-bake.
  bool get dartColorGain => _dartColorGain;

  /// Bake an object-space normal map (`*_n.png`) from the TrueDepth face mesh
  /// into the UV atlas. Default off. Re-bake to apply.
  bool get bakeNormalMap => _bakeNormalMap;

  /// Target camera↔face distance for the face-frame gate (metres). Closer =
  /// more face pixels in the still → sharper bake. Live: no rebuild needed.
  double get targetDistanceMeters => _targetDistanceMeters;

  /// On-device ml-wb CoreML white-balance on pose stills before bake. Default
  /// on. Re-bake to apply.
  bool get mlWb => _mlWb;

  /// Only when [mlWb] is on: `true` = all poses → frontal still's estimated
  /// Kelvin; `false` (default) = all poses → neutral 5600 K. Re-bake to apply.
  bool get mlWbMatchFrontal => _mlWbMatchFrontal;

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

  set hiResPhoto(bool value) {
    if (value != _hiResPhoto) {
      _hiResPhoto = value;
      notifyListeners();
    }
  }

  set lockAeAwb(bool value) {
    if (value != _lockAeAwb) {
      _lockAeAwb = value;
      notifyListeners();
    }
  }

  set chinUpLowerFace(bool value) {
    if (value != _chinUpLowerFace) {
      _chinUpLowerFace = value;
      notifyListeners();
    }
  }

  set viewDependent(bool value) {
    if (value != _viewDependent) {
      _viewDependent = value;
      notifyListeners();
    }
  }

  set viewBestOnly(bool value) {
    if (value != _viewBestOnly) {
      _viewBestOnly = value;
      notifyListeners();
    }
  }

  set dartColorGain(bool value) {
    if (value != _dartColorGain) {
      _dartColorGain = value;
      notifyListeners();
    }
  }

  set bakeNormalMap(bool value) {
    if (value != _bakeNormalMap) {
      _bakeNormalMap = value;
      notifyListeners();
    }
  }

  set targetDistanceMeters(double value) {
    final double clamped = value.clamp(
      PoseTolerance.kMinTargetDistanceMeters,
      PoseTolerance.kMaxTargetDistanceMeters,
    );
    if (clamped != _targetDistanceMeters) {
      _targetDistanceMeters = clamped;
      notifyListeners();
    }
  }

  set mlWb(bool value) {
    if (value != _mlWb) {
      _mlWb = value;
      notifyListeners();
    }
  }

  set mlWbMatchFrontal(bool value) {
    if (value != _mlWbMatchFrontal) {
      _mlWbMatchFrontal = value;
      notifyListeners();
    }
  }
}
