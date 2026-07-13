# Architecture — flutter_face_scan

TrueDepth-based dermatological 3D face analysis (iOS). Clean, layered, BLoC.
The guiding rule: **business logic never imports `arkit_plugin` or Flutter.**

## Layers (`lib/features/face_capture/`)

```
domain/        Pure Dart. No Flutter, no ARKit. Fully unit-testable.
  constants/   Symmetry-axis vertex index table (single source of truth).
  entities/    Immutable value objects (Equatable): EulerAngles, FacePose,
               FaceObservation, CaptureSnapshot, SymmetryAxis, PoseValidation…
  value_objects/  PoseTolerance (capture strictness knobs).
  services/    Abstract ports: FaceTrackingService, PoseValidator,
               SymmetryAxisExtractor.
  logic/       Pure implementations: GuidedPoseValidator,
               LeastSquaresSymmetryAxisExtractor.
  v2/          Dynamic-capture (expression) interface + stubs.
  v3/          Reconstruction dataset structures + builder stub.

application/   BLoC (the state machine). Orchestrates domain only.
  capture_bloc / capture_event / capture_state / capture_status

data/          The ONLY channel-aware code.
  arkit_face_tracking_service.dart  (implements FaceTrackingService over the
                                     native platform channel; decodes frames)
  mappers/face_anchor_mapper.dart   (primitives -> FaceObservation; pure)

presentation/  Flutter UI. Dumb: renders CaptureState, hosts the preview view.
  capture_page / widgets/capture_overlay / pose_guidance_copy
```

### Why a native channel, not `arkit_plugin`

`arkit_plugin` does **not** expose the `ARFaceGeometry` vertex buffer
(~1220 verts) to Dart — its `ARKitFace` geometry only carries materials/
triangle metadata. The symmetry-axis trigger and V3 reconstruction need the
vertices, so ARKit is driven directly in Swift
(`ios/Runner/FaceTracking/*.swift`): an `ARFaceTrackingConfiguration` session
streams `{timestampMicros, isTracked, transform[16], vertices(Float32),
blendShapes}` over an `EventChannel`; `start`/`stop` go over a `MethodChannel`;
the live `ARSCNView` is surfaced to Flutter as a `UiKitView` preview. The Dart
`FaceTrackingService` port is unchanged, so domain/BLoC/tests never noticed the
swap.

> Xcode setup: add `ios/Runner/FaceTracking/*.swift` to the Runner target if
> they aren't picked up automatically, and run on a TrueDepth device (the
> simulator has no face tracking).

Dependency direction: `presentation → application → domain ← data`.
Domain depends on nothing app-specific.

## V1 — Guided Capture (implemented)

State machine: `idle → capturing → completed | error`.
Sequence `FacePose.captureSequence` = frontal → left40 → right40.

Per frame the BLoC asks `PoseValidator`:
- Euler angles within `PoseTolerance` of the pose's target yaw (+ neutral
  pitch/roll), AND
- the fitted **symmetry axis** (forehead→chin vertices) is upright with a clean
  line-fit residual.

`requiredStableFrames` consecutive on-target frames auto-trigger a
`CaptureSnapshot`; a miss resets the counter. Snapshots store the full
observation (vertices + blendshapes) so V3 needs no re-capture.

## V2 — Dynamic Capture (stubbed)

`DynamicCaptureStrategy` behind the same `PoseValidator`-style seam.
Recommendation baked into the docs: **blendshape-keyed snapshot series** over
video — reuses the V1 pipeline, deterministic, testable, V3-ready. Video kept
as an alternative behind the interface if temporal dynamics prove necessary.

## V3 — 3D Reconstruction (stubbed)

`ReconstructionDataset` = per-pose `PosePointCloud`s (vertices +
anchor→world transform). `ReconstructionDatasetBuilder` aggregates the
snapshots; alignment/merging strategy is the V3 work item.

## Testability

Logic is isolated from device + UI:
- `test/domain/` — vertex table invariants, symmetry-axis fit (tilt/residual),
  pose validation rules.
- `test/application/` — BLoC sequence, stability-counter reset, error path,
  driven by a fake `FaceTrackingService` + scripted `PoseValidator`.
- `test/support/face_observation_fixtures.dart` — builds synthetic frames.

## Consistency / automation

- `analysis_options.yaml` — strict casts/inference + opinionated lints; one
  ruleset so the code reads "from one hand". CI runs
  `dart format --set-exit-if-changed .` and `flutter analyze`.

## Calibration notes

- The symmetry-axis vertex indices (`FaceSymmetryAxis`) were author-derived and
  marked "not 100% certain" — isolated in one file, asserted in tests.
- Euler sign/axis mapping is centralised in `FaceAnchorMapper.eulerFromTransform`;
  if on-device testing shows an inverted axis, flip it there only.
- A calibration HUD (`presentation/debug/capture_debug_hud.dart`) shows live
  Euler + axis-fit numbers for verifying both of the above. It is gated by the
  compile-time `kCaptureDebugHud` (`bool.fromEnvironment`, default `false`), so
  it tree-shakes out of release builds — the capture flow never depends on it.
  Enable: `flutter run --dart-define=CAPTURE_DEBUG_HUD=true` (tap the badge to
  hide at runtime).
