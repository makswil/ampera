# `face_capture` feature

Self-contained TrueDepth face-capture feature. **This whole folder is the unit
meant to be lifted into the real app** — the surrounding project is only a husk
to prove TrueDepth works through Flutter.

## What each file does

### `domain/` — pure Dart, no Flutter, no ARKit (portable + unit-tested)

| File | Responsibility |
| --- | --- |
| `constants/face_vertex_indices.dart` | `FaceSymmetryAxis`: the forehead→chin vertex index table (single source of truth, author-flagged "uncertain"). |
| `entities/euler_angles.dart` | Head orientation (yaw/pitch/roll, degrees) + sign convention. |
| `entities/face_pose.dart` | `FacePose` enum: frontal / left40 / right40 + capture order. |
| `entities/face_blendshape.dart` | Typed ARKit blendshape keys (for V2). |
| `entities/face_observation.dart` | One mapped tracking frame (verts + blendshapes + euler). The only shape the logic consumes. |
| `entities/symmetry_axis.dart` | Fitted 3D midline: origin, direction, tilt, residual. |
| `entities/screen_alignment.dart` | 2D screen-projected midline fit: tilt, straightness, centre offset. |
| `entities/pose_guidance.dart` | UI-agnostic correction hints (turnLeft, lookUp…). |
| `entities/pose_validation.dart` | Result of validating one frame (on-target? + errors). |
| `entities/capture_snapshot.dart` | An accepted frame frozen for a pose. |
| `entities/capture_session.dart` | A completed run (id + snapshots); input to persistence. |
| `entities/saved_session.dart` | Reference to a persisted session on disk (paths). |
| `value_objects/pose_tolerance.dart` | Acceptance thresholds (tunable in one place). |
| `services/face_tracking_service.dart` | **Port** to a tracking source (the seam ARKit plugs into). |
| `services/pose_validator.dart` | **Port** for pose acceptance. |
| `services/symmetry_axis_extractor.dart` | **Port** for axis fitting. |
| `services/snapshot_repository.dart` | **Port** for persisting a completed session. |
| `logic/guided_pose_validator.dart` | Default validator (euler + axis checks). Pure. |
| `logic/least_squares_symmetry_axis_extractor.dart` | Total-least-squares 3D line fit. Pure. |
| `logic/screen_axis_aligner.dart` | 2D line fit of the projected midline (facing-camera gate). Pure. |
| `v2/dynamic_capture_strategy.dart` | V2 stub: expression capture interface + recommendation. |
| `v3/reconstruction_dataset.dart` | V3 stub: per-pose point-cloud dataset + builder. |

### `application/` — the state machine (BLoC), orchestrates domain only

| File | Responsibility |
| --- | --- |
| `capture_status.dart` | Phase enum: idle / capturing / completed / error. |
| `capture_event.dart` | Inputs: start, stop, reset, frame received, failed. |
| `capture_state.dart` | Immutable session state + progress getters. |
| `capture_bloc.dart` | Drives the guided sequence; stability counter → snapshot. |

### `data/` — the ONLY ARKit/channel-aware code

| File | Responsibility |
| --- | --- |
| `arkit_face_tracking_service.dart` | Implements the tracking port over the native platform channel; decodes frames; `setOverlay()` toggles the verification mesh. |
| `mappers/face_anchor_mapper.dart` | Channel primitives → `FaceObservation`; centralises the Euler extraction. Pure. |
| `file_snapshot_repository.dart` | Writes a session to disk: PLY point cloud per pose + `manifest.json`. |

### `presentation/` — Flutter UI (dumb; renders `CaptureState`)

| File | Responsibility |
| --- | --- |
| `capture_page.dart` | Wires deps, hosts the native preview `UiKitView`, overlays UI. |
| `widgets/capture_overlay.dart` | Pose chips + guidance card + hold progress. |
| `pose_guidance_copy.dart` | Enum → user-facing strings (i18n seam). |
| `debug/capture_debug_hud.dart` | Calibration HUD + the two compile-time debug flags (`kCaptureDebugHud`, `kFaceMeshOverlay`). |

## Dependency direction

```
presentation ─▶ application ─▶ domain ◀─ data
```

Domain depends on nothing app-specific. Swap `data/` and you can run the whole
feature against a fake tracker (see `test/`).

## Exporting into the real app

Portable unit = **this `face_capture/` folder + the native Swift block**
(currently in `ios/Runner/AppDelegate.swift`, channels named
`flutter_face_scan/face_tracking*`).

To move it:

1. Copy `lib/features/face_capture/` into the host project.
2. Bring the iOS native code across. For a clean integration, extract the Swift
   into a proper **Flutter plugin** (or the host app's iOS target) and keep the
   channel names — nothing in Dart changes.
3. Add deps: `flutter_bloc`, `bloc`, `equatable`, `vector_math`.
4. Add `NSCameraUsageDescription` to the host `Info.plist`.
5. Push the route: `Navigator.push(... CapturePage())`.

Only two things touch the outside world: the channel names (data layer) and
`CapturePage` (entry widget). Everything else is internal.

## Debug flags

Use a profile file — no need to type individual flags:

```
flutter run --dart-define-from-file=dart_defines/dev.json
```

| Profile | HUD | Mesh | Use for |
| --- | --- | --- | --- |
| `dart_defines/dev.json` | ✓ | ✓ | Full calibration session |
| `dart_defines/hud_only.json` | ✓ | – | Checking Euler numbers only |
| `dart_defines/mesh_only.json` | – | ✓ | Checking vertex/midline visually |
| `dart_defines/release.json` | – | – | Clean run (same as no flags) |

All flags default to `false` and are dead-code-eliminated from release builds.
Add new flags to every profile file to keep them in sync.
