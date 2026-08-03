import 'package:flutter/foundation.dart';

import '../../domain/constants/capture_defaults.dart';
import '../../domain/entities/capture_actor_mode.dart';
import '../../domain/value_objects/pose_tolerance.dart';

/// Runtime-toggleable debug flags and product scan-mode picks.
///
/// Defaults live here; the Settings UI flips them at runtime (no rebuild,
/// no compile-time flags).
class DebugSettings extends ChangeNotifier {
  DebugSettings({
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
    AppRole? appRole,
    CaptureActorMode? actorMode,
    PractitionerFlow? practitionerFlow,
    MeshMotionMode? meshMotion,
    ClinicianCamera? clinicianCamera,
    RearCaptureKind? rearCaptureKind,
    String? meshRefSessionId,
    CaptureStabilityProfile? stabilityProfile,
  }) : _fillHoles = fillHoles ?? true,
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
       _mlWbMatchFrontal = mlWbMatchFrontal ?? false,
       _appRole = appRole ?? AppRole.user,
       _actorMode = actorMode ??
           (appRole ?? AppRole.user).lockedActorMode ??
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

  /// Texture source: false = ARKit video frame (stable), true = AVCapture hi-res
  /// still. Default on.
  bool get hiResPhoto => _hiResPhoto;

  /// After the first pose photo (front hi-res or rear still/video) settles
  /// AE/AWB, lock ISO/shutter/WB gains and reuse for later poses in that
  /// camera session. Default on. New scan / camera switch clears the lock.
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
  /// Kelvin; `false` (default) = all poses → [CaptureDefaults.neutralKelvin].
  /// Re-bake to apply.
  bool get mlWbMatchFrontal => _mlWbMatchFrontal;

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
