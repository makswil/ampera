import 'package:flutter/foundation.dart';

import '../../domain/constants/capture_defaults.dart';
import '../../domain/constants/expression_sequence_config.dart';
import '../../domain/entities/capture_actor_mode.dart';
import '../../domain/value_objects/pose_tolerance.dart';

/// Runtime-toggleable debug flags and product scan-mode picks.
///
/// Defaults live here; the Settings UI flips them at runtime (no rebuild,
/// no compile-time flags).
class DebugSettings extends ChangeNotifier {
  DebugSettings({
    bool? fillHoles,
    bool? debugSourceColors,
    bool? hiResPhoto,
    bool? lockAeAwb,
    bool? chinUpLowerFace,
    bool? viewDependent,
    bool? viewBestOnly,
    bool? dartColorGain,
    bool? bakeNormalMap,
    double? targetDistanceMeters,
    bool? mlWb,
    bool? mlWbExpression,
    bool? mlWbMatchFrontal,
    int? expressionFps,
    bool? forceFirstLaunch,
    AppRole? appRole,
    CaptureActorMode? actorMode,
    PractitionerFlow? practitionerFlow,
    MeshMotionMode? meshMotion,
    ClinicianCamera? clinicianCamera,
    RearCaptureKind? rearCaptureKind,
    String? meshRefSessionId,
    CaptureStabilityProfile? stabilityProfile,
  }) : _fillHoles = fillHoles ?? true,
       _debugSourceColors = debugSourceColors ?? false,
       _hiResPhoto = hiResPhoto ?? false,
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
       _mlWbExpression = mlWbExpression ?? false,
       _mlWbMatchFrontal = mlWbMatchFrontal ?? false,
       _expressionFps = (expressionFps ?? ExpressionSequenceConfig.targetFps.round())
           .clamp(
             ExpressionSequenceConfig.minFps,
             ExpressionSequenceConfig.maxFps,
           ),
       _forceFirstLaunch = forceFirstLaunch ?? true,
       _appRole = appRole ?? AppRole.developer,
       _actorMode = actorMode ??
           (appRole ?? AppRole.developer).lockedActorMode ??
           CaptureActorMode.user,
       _practitionerFlow = practitionerFlow ?? PractitionerFlow.meshThenPhotos,
       _meshMotion = meshMotion ?? MeshMotionMode.device,
       _clinicianCamera = clinicianCamera ?? ClinicianCamera.front,
       _rearCaptureKind = rearCaptureKind ?? RearCaptureKind.still,
       _meshRefSessionId = meshRefSessionId,
       _stabilityProfile =
           stabilityProfile ?? CaptureStabilityProfile.handheld;

  bool _showHud = false;
  bool _showMesh = false;
  bool _fillHoles;
  bool _debugSourceColors;
  bool _hiResPhoto;
  bool _lockAeAwb;
  bool _chinUpLowerFace;
  bool _viewDependent;
  bool _viewBestOnly;
  bool _dartColorGain;
  bool _bakeNormalMap;
  double _targetDistanceMeters;
  bool _mlWb;
  bool _mlWbExpression;
  bool _mlWbMatchFrontal;
  int _expressionFps;
  bool _forceFirstLaunch;
  bool _howToShownNeutralThisLaunch = false;
  bool _howToShownSmileThisLaunch = false;
  AppRole _appRole;
  CaptureActorMode _actorMode;
  PractitionerFlow _practitionerFlow;
  MeshMotionMode _meshMotion;
  ClinicianCamera _clinicianCamera;
  RearCaptureKind _rearCaptureKind;
  String? _meshRefSessionId;
  CaptureStabilityProfile _stabilityProfile;

  /// Calibration HUD (Dev settings). Default off.
  bool get showHud => _showHud;

  /// Native face-mesh + symmetry-axis overlay. Default off.
  bool get showMesh => _showMesh;

  /// Whether eye strip-tris are added (on) or eye holes stay open (off) in the
  /// baked model. Mouth is never filled. Default on.
  bool get fillHoles => _fillHoles;

  /// Expression bake paints source colours (frontal=green, left=red, right=blue)
  /// instead of photos. Default on while diagnosing mix. Generate again to apply.
  bool get debugSourceColors => _debugSourceColors;

  /// Texture source for **rear** capture only. Front 4-pose + expression always
  /// use ARKit video frames (one session / one AE·AWB lock). Default off.
  bool get hiResPhoto => _hiResPhoto;

  /// After the first pose: lock ISO/shutter/WB on TrueDepth and keep it through
  /// a following expression clip (same ARKit session). Default on.
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
  /// `false` (default) = weighted blend (smoother colour). Generate again to apply.
  bool get viewBestOnly => _viewBestOnly;

  /// Only when [viewDependent] is on: Dart `poseGain` — match each pose's mean
  /// RGB to frontal over their overlap. Default off (A/B with ml-wb). Generate again.
  bool get dartColorGain => _dartColorGain;

  /// Bake an object-space normal map (`*_n.png`) from the TrueDepth face mesh
  /// into the UV atlas. Default off. Generate again to apply.
  bool get bakeNormalMap => _bakeNormalMap;

  /// Target camera↔face distance for the face-frame gate (metres). Closer =
  /// more face pixels in the still → sharper bake. Live: no rebuild needed.
  double get targetDistanceMeters => _targetDistanceMeters;

  /// On-device ml-wb CoreML white-balance before **4-pose** Generate.
  /// Default on. Expression clip uses [mlWbExpression] instead.
  bool get mlWb => _mlWb;

  /// On-device ml-wb before **every expression-clip frame**. Default off
  /// (55+ frames). L/R/chin-up stills are always matched to one clip frame
  /// even when this is off.
  bool get mlWbExpression => _mlWbExpression;

  /// Only when [mlWb] / [mlWbExpression] is on: `true` = all inputs → frontal
  /// still's estimated Kelvin; `false` (default) = → [CaptureDefaults.neutralKelvin].
  /// Generate again to apply.
  bool get mlWbMatchFrontal => _mlWbMatchFrontal;

  /// Expression-clip sample rate (fps) while buffering / recording. 1–60;
  /// default [ExpressionSequenceConfig.targetFps]. Applies on the next clip.
  int get expressionFps => _expressionFps;

  /// When true, the how-to shows once per app launch (again after
  /// `flutter run`), ignoring the on-disk seen flag. Default on.
  bool get forceFirstLaunch => _forceFirstLaunch;

  /// True after the 3D-model how-to was shown or dismissed this process.
  bool get howToShownThisLaunch =>
      howToShownThisLaunchFor(smile: false);

  /// Whether this process already showed the how-to for [smile] vs 3D model.
  bool howToShownThisLaunchFor({required bool smile}) =>
      smile ? _howToShownSmileThisLaunch : _howToShownNeutralThisLaunch;

  /// Marks the 3D-model how-to as consumed until the next process start.
  void markHowToShownThisLaunch() {
    markHowToShownThisLaunchFor(smile: false);
  }

  /// Marks the how-to for [smile] vs 3D model as consumed this process.
  void markHowToShownThisLaunchFor({required bool smile}) {
    if (smile) {
      if (!_howToShownSmileThisLaunch) {
        _howToShownSmileThisLaunch = true;
        notifyListeners();
      }
      return;
    }
    if (!_howToShownNeutralThisLaunch) {
      _howToShownNeutralThisLaunch = true;
      notifyListeners();
    }
  }

  /// Product UI role (User / Clinician / Dev) — gates settings chrome.
  AppRole get appRole => _appRole;

  /// True when [appRole] is [AppRole.developer].
  bool get isDev => _appRole == AppRole.developer;

  /// Who operates the device (User vs Clinician).
  CaptureActorMode get actorMode => _actorMode;

  /// Clinician mesh strategy (mesh now vs prior mesh).
  PractitionerFlow get practitionerFlow => _practitionerFlow;

  /// Mesh-pass motion (head vs iPad). Only for clinician + mesh now.
  MeshMotionMode get meshMotion => _meshMotion;

  /// Clinician photo camera (front vs rear).
  ClinicianCamera get clinicianCamera => _clinicianCamera;

  /// Rear capture kind (photo vs video). Ignored unless rear is selected.
  RearCaptureKind get rearCaptureKind => _rearCaptureKind;

  /// Session id for [PractitionerFlow.reuseMeshRef] (bakeable prior mesh).
  String? get meshRefSessionId => _meshRefSessionId;

  /// Handheld vs tripod acceptance profile.
  CaptureStabilityProfile get stabilityProfile => _stabilityProfile;

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

  set debugSourceColors(bool value) {
    if (value != _debugSourceColors) {
      _debugSourceColors = value;
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

  set mlWbExpression(bool value) {
    if (value != _mlWbExpression) {
      _mlWbExpression = value;
      notifyListeners();
    }
  }

  set mlWbMatchFrontal(bool value) {
    if (value != _mlWbMatchFrontal) {
      _mlWbMatchFrontal = value;
      notifyListeners();
    }
  }

  set expressionFps(int value) {
    final int clamped = value.clamp(
      ExpressionSequenceConfig.minFps,
      ExpressionSequenceConfig.maxFps,
    );
    if (clamped != _expressionFps) {
      _expressionFps = clamped;
      notifyListeners();
    }
  }

  set forceFirstLaunch(bool value) {
    if (value != _forceFirstLaunch) {
      _forceFirstLaunch = value;
      notifyListeners();
    }
  }

  set appRole(AppRole value) {
    if (value == _appRole) {
      return;
    }
    _appRole = value;
    final CaptureActorMode? locked = value.lockedActorMode;
    if (locked != null) {
      _actorMode = locked;
    }
    // Tripod/stability is clinician-only; User falls back to handheld.
    if (_actorMode != CaptureActorMode.practitioner) {
      _stabilityProfile = CaptureStabilityProfile.handheld;
    }
    notifyListeners();
  }

  set actorMode(CaptureActorMode value) {
    // Non-dev roles keep actor locked to the role.
    final CaptureActorMode? locked = _appRole.lockedActorMode;
    final CaptureActorMode next = locked ?? value;
    if (next != _actorMode) {
      _actorMode = next;
      if (next != CaptureActorMode.practitioner) {
        _stabilityProfile = CaptureStabilityProfile.handheld;
      }
      notifyListeners();
    }
  }

  set practitionerFlow(PractitionerFlow value) {
    if (value != _practitionerFlow) {
      _practitionerFlow = value;
      if (value != PractitionerFlow.reuseMeshRef) {
        _meshRefSessionId = null;
      }
      notifyListeners();
    }
  }

  set meshRefSessionId(String? value) {
    if (value != _meshRefSessionId) {
      _meshRefSessionId = value;
      notifyListeners();
    }
  }

  set meshMotion(MeshMotionMode value) {
    if (value != _meshMotion) {
      _meshMotion = value;
      notifyListeners();
    }
  }

  set clinicianCamera(ClinicianCamera value) {
    if (value != _clinicianCamera) {
      _clinicianCamera = value;
      notifyListeners();
    }
  }

  set rearCaptureKind(RearCaptureKind value) {
    if (value != _rearCaptureKind) {
      _rearCaptureKind = value;
      notifyListeners();
    }
  }

  set stabilityProfile(CaptureStabilityProfile value) {
    if (value != _stabilityProfile) {
      _stabilityProfile = value;
      notifyListeners();
    }
  }
}
