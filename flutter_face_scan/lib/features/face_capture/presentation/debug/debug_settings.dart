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
    bool? hiResPhoto,
    bool? chinUpLowerFace,
    bool? viewDependent,
    bool? viewBestOnly,
    bool? viewColorMatch,
    bool? viewColorNeutral,
  }) : _showHud = showHud ?? kCaptureDebugHud,
       _showMesh = showMesh ?? kFaceMeshOverlay,
       _fillHoles = fillHoles ?? true,
       _hiResPhoto = hiResPhoto ?? false,
       _chinUpLowerFace = chinUpLowerFace ?? true,
       _viewDependent = viewDependent ?? false,
       _viewBestOnly = viewBestOnly ?? false,
       _viewColorMatch = viewColorMatch ?? true,
       _viewColorNeutral = viewColorNeutral ?? false;

  bool _showHud;
  bool _showMesh;
  bool _fillHoles;
  bool _hiResPhoto;
  bool _chinUpLowerFace;
  bool _viewDependent;
  bool _viewBestOnly;
  bool _viewColorMatch;
  bool _viewColorNeutral;

  bool get showHud => _showHud;
  bool get showMesh => _showMesh;

  /// Whether the open eye/mouth holes are capped + textured (on) or left as
  /// holes (off) in the baked model. Default on.
  bool get fillHoles => _fillHoles;

  /// Texture source: false = ARKit video frame (stable), true = AVCapture hi-res
  /// still. Default false so the working path is always one tap away.
  bool get hiResPhoto => _hiResPhoto;

  /// Whether the lower/under face (chin, jaw underside) is sourced from the
  /// chin-up pose (on) or left on the frontal source (off). Default on. Turn off
  /// to A/B or if the chin-up blend ghosts.
  bool get chinUpLowerFace => _chinUpLowerFace;

  /// View-dependent (normal-based, `n·v`) texture blend (on) vs. the static
  /// region tables (off). Default off so it's an explicit A/B against the
  /// current pipeline. When on, each pose contributes per surface point by how
  /// head-on it saw it, gated by per-pose spatial guards.
  bool get viewDependent => _viewDependent;

  /// Only relevant when [viewDependent] is on: `true` = best-only (take the
  /// single highest-`n·v` pose per texel → maximally sharp, but seams where the
  /// winner switches). `false` (default) = weighted blend (smooth seams,
  /// slightly softer). Re-bake to apply.
  bool get viewBestOnly => _viewBestOnly;

  /// Only relevant when [viewDependent] is on: `true` (default) = colour-match
  /// each pose to frontal over their overlap (removes exposure/white-balance
  /// seams). `false` = raw pose colours. Re-bake to apply.
  bool get viewColorMatch => _viewColorMatch;

  /// Only relevant when [viewColorMatch] is on: `false` (default) = match every
  /// pose to the FRONTAL exposure/white-balance over their overlap. `true` =
  /// neutral: normalise every pose (incl. frontal) to the shared average colour
  /// (no privileged pose). Re-bake to apply.
  bool get viewColorNeutral => _viewColorNeutral;

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

  set viewColorMatch(bool value) {
    if (value != _viewColorMatch) {
      _viewColorMatch = value;
      notifyListeners();
    }
  }

  set viewColorNeutral(bool value) {
    if (value != _viewColorNeutral) {
      _viewColorNeutral = value;
      notifyListeners();
    }
  }
}
