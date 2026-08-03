/// UI / product role that gates settings chrome and toolbar tools.
///
/// Distinct from [CaptureActorMode]: User/Clinician also lock the scan actor;
/// Dev keeps [CaptureActorMode] free so both flows stay testable.
enum AppRole {
  /// Patient self-scan; clean settings.
  user(label: 'User'),

  /// Clinic operator; clinician scan options visible.
  clinician(label: 'Clinician'),

  /// Developer: all toggles, bake settings, and scan-operator picker.
  developer(label: 'Dev');

  const AppRole({required this.label});

  /// Short UI label for pickers.
  final String label;

  /// Locked [CaptureActorMode] for this role, or null when Dev (free pick).
  CaptureActorMode? get lockedActorMode => switch (this) {
        AppRole.user => CaptureActorMode.user,
        AppRole.clinician => CaptureActorMode.practitioner,
        AppRole.developer => null,
      };

  static AppRole fromName(String? name) {
    if (name == null || name.isEmpty) {
      return AppRole.user;
    }
    for (final AppRole role in AppRole.values) {
      if (role.name == name) {
        return role;
      }
    }
    return AppRole.user;
  }
}

/// Who operates the device during a guided scan.
enum CaptureActorMode {
  /// Patient holds the device and moves their head (legacy / default).
  user(label: 'User'),

  /// Practitioner moves the device around a still patient.
  practitioner(label: 'Clinician');

  const CaptureActorMode({required this.label});

  /// Short UI label for pickers.
  final String label;

  /// Parse a persisted name; unknown / null → [user].
  static CaptureActorMode fromName(String? name) {
    if (name == null || name.isEmpty) {
      return CaptureActorMode.user;
    }
    for (final CaptureActorMode mode in CaptureActorMode.values) {
      if (mode.name == name) {
        return mode;
      }
    }
    return CaptureActorMode.user;
  }
}

/// How a clinician scan obtains mesh vs photos.
///
/// Only meaningful when [CaptureActorMode.practitioner] is selected.
enum PractitionerFlow {
  /// Capture a fresh front TrueDepth mesh, then photos (front or rear).
  meshThenPhotos(label: 'Mesh now'),

  /// Reuse mesh from an earlier session; clinician captures photos only.
  ///
  /// Requires a selected [meshRefSessionId] with bakeable mesh. Bake stays on
  /// the prior mesh epoch stills; new photos are enrichment (`rearStills`).
  reuseMeshRef(label: 'Prior mesh');

  const PractitionerFlow({required this.label});

  /// Short UI label for pickers.
  final String label;

  /// Parse a persisted name; unknown / null → [meshThenPhotos].
  static PractitionerFlow fromName(String? name) {
    if (name == null || name.isEmpty) {
      return PractitionerFlow.meshThenPhotos;
    }
    for (final PractitionerFlow flow in PractitionerFlow.values) {
      if (flow.name == name) {
        return flow;
      }
    }
    return PractitionerFlow.meshThenPhotos;
  }
}

/// Who moves during the front TrueDepth **mesh** pass.
///
/// Only meaningful for clinician + [PractitionerFlow.meshThenPhotos]. Rear
/// photos always use device orbit; this chooses the mesh-pass style.
enum MeshMotionMode {
  /// Patient turns their head (self-scan style); device stays put.
  head(label: 'Head'),

  /// Clinician orbits the iPad; patient holds still.
  device(label: 'iPad');

  const MeshMotionMode({required this.label});

  final String label;

  static MeshMotionMode fromName(String? name) {
    if (name == null || name.isEmpty) {
      return MeshMotionMode.device;
    }
    for (final MeshMotionMode mode in MeshMotionMode.values) {
      if (mode.name == name) {
        return mode;
      }
    }
    return MeshMotionMode.device;
  }
}

/// Camera used for the clinician photo pass.
///
/// Mesh always uses front TrueDepth when a mesh pass runs. This selects the
/// photo/video camera for clinician capture.
enum ClinicianCamera {
  /// Front TrueDepth (same camera as today's self-scan stills).
  front(label: 'Front'),

  /// Rear wide camera (hi-res photo / 4K video — backend later).
  rear(label: 'Rear');

  const ClinicianCamera({required this.label});

  final String label;

  static ClinicianCamera fromName(String? name) {
    if (name == null || name.isEmpty) {
      return ClinicianCamera.front;
    }
    for (final ClinicianCamera camera in ClinicianCamera.values) {
      if (camera.name == name) {
        return camera;
      }
    }
    return ClinicianCamera.front;
  }
}

/// Which pass is active in a sequential clinician mesh→photo run.
enum CapturePass {
  /// Front TrueDepth mesh (+ bake stills).
  mesh,

  /// Photo/video pass (front or rear) after mesh.
  photo,
}

/// Resolves which guidance copy/hints to show for the current run.
///
/// Photo/rear passes are always clinician orbit. Head-mesh style only applies
/// on the front mesh pass.
CaptureActorMode guidanceActorMode({
  required CaptureActorMode actorMode,
  required PractitionerFlow practitionerFlow,
  required MeshMotionMode meshMotion,
  ClinicianCamera clinicianCamera = ClinicianCamera.front,
  CapturePass? capturePass,
}) {
  if (actorMode != CaptureActorMode.practitioner) {
    return CaptureActorMode.user;
  }
  if (capturePass == CapturePass.photo ||
      clinicianCamera == ClinicianCamera.rear) {
    return CaptureActorMode.practitioner;
  }
  // Front mesh-now + patient head movement → self-scan style prompts.
  if (practitionerFlow == PractitionerFlow.meshThenPhotos &&
      meshMotion == MeshMotionMode.head) {
    return CaptureActorMode.user;
  }
  return CaptureActorMode.practitioner;
}

/// How rear clinician frames are captured.
///
/// Only meaningful when [ClinicianCamera.rear] is selected. Front stills stay
/// on the existing AVCapture hi-res path.
enum RearCaptureKind {
  /// Discrete still photos per pose.
  still(label: 'Photo'),

  /// Video orbit; sharp frames filtered later.
  video(label: 'Video');

  const RearCaptureKind({required this.label});

  final String label;

  static RearCaptureKind fromName(String? name) {
    if (name == null || name.isEmpty) {
      return RearCaptureKind.still;
    }
    for (final RearCaptureKind kind in RearCaptureKind.values) {
      if (kind.name == name) {
        return kind;
      }
    }
    return RearCaptureKind.still;
  }
}
