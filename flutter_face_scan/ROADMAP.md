# Roadmap — flutter_face_scan

Status legend: `[x]` done · `[~]` in progress / partial · `[ ]` todo

---

## Phase 0 — Foundation (done)

- [x] Clean layered architecture (domain / application / data / presentation)
- [x] BLoC guided-capture state machine (frontal → left40 → right40)
- [x] Pure pose validation + symmetry-axis fit (isolated, unit-tested)
- [x] Native TrueDepth platform channel (vertices + blendshapes + transform)
- [x] Live ARKit preview as `UiKitView`
- [x] Strict lints, 17 passing tests, `flutter analyze` clean
- [x] Compile-time-gated calibration HUD
- [x] Live verification mesh overlay (green wireframe + red symmetry-axis dots)
- [x] Feature README + export boundary documented (`lib/features/face_capture/README.md`)
- [x] Swift consolidated into AppDelegate (no Xcode target step needed)

---

## Phase 1 — On-device calibration & V1 hardening (next)

- [x] Verify symmetry-axis vertex table (confirmed correct on device)
- [x] Verify Euler sign/axis mapping (pitch/yaw confirmed working)
- [x] Fix first-frame bias → camera-relative Euler (`inverse(camera)·face`)
- [x] 2D screen-axis "facing camera" gate for frontal (straight + centred)
- [x] Fix roll bias → image-plane roll from face up-vector (yaw/pitch-independent)
- [x] Capture feedback: white flash per snapshot + "Captured N/3" + hold bar
- [ ] Tune tolerances from real captures: `PoseTolerance` 2D thresholds
      (`maxScreenAxisTiltDegrees`, `maxScreenStraightness`, `maxScreenCenterOffset`)
      + yaw/pitch/roll + residual + frames
- [ ] Unsupported-device UX (no TrueDepth → clear message, not silent fail)
- [ ] Camera-permission-denied UX + "open Settings" path
- [ ] App-lifecycle handling: pause/resume AR session on background/foreground
- [ ] Capture countdown / haptic + sound on snapshot
- [ ] Retake / restart flow from the UI (event exists; wire a button)
- [ ] Golden tests for `FaceAnchorMapper.eulerFromTransform` once signs confirmed

## Phase 2 — Snapshot persistence & export

- [x] `SnapshotRepository` port (domain) + `FileSnapshotRepository` (data)
- [x] Serialize per pose: ASCII-PLY point cloud + JSON manifest (pose, Euler,
      blendshapes, world transform); `transformStorage` added to observation
- [x] Session folder layout + manifest (id, createdAt, schemaVersion, poses)
- [x] Save-on-completion wired into `CapturePage` (+ saved banner)
- [x] Repository unit tests (manifest + PLY structure, temp dir)
- [ ] Share sheet (share_plus) / upload hook — get files off-device
- [ ] Device test: confirm files land in app documents + open in a mesh viewer

## Phase 3 — V2 Dynamic (expression) capture

- [x] Expression mode picker reuses the V1 guided scan (no second pipeline)
- [x] `ExpressionAwarePoseValidator` decorator + Smile blendshape gate
- [x] Manifest `expression` + schemaVersion 3 (legacy → neutral)
- [x] Guidance copy + scan-list label
- [x] Unit tests for gate, bloc mode, manifest/list
- [ ] (Optional) more modes beyond smile (jawOpen, browsUp, …)
- [ ] (Optional) shorten non-neutral pose set to frontal if side-smile UX fails
- [ ] (Optional) evaluate short video sequences if dynamics prove necessary

## Phase 4 — V3 3D reconstruction

- [ ] Implement `ReconstructionDatasetBuilder` (align per-pose clouds via
      their world transforms)
- [ ] Merge / stitch frontal + 40° views into one model
- [ ] Export unified mesh (`.ply` / `.obj`) for downstream dermatology analysis
- [ ] Quality metrics (coverage, overlap, alignment error)
- [ ] Tests on recorded fixture sessions

---

## Tooling / UX (done)

- [x] Runtime debug menu (⚙ in debug builds): toggle HUD + mesh overlay live
- [x] Manage-scans screen: list saved sessions, delete individually / clear all
- [x] Decision: no per-user turn calibration (fixed angle for symmetry consistency)

## Cross-cutting (ongoing)

- [ ] CI pipeline: `dart format --set-exit-if-changed`, `analyze`, `test`
- [ ] Performance: throttle/decimate frame stream if UI jank on device
- [ ] Memory: vertex buffers are large — avoid retaining every frame
- [ ] Accessibility: VoiceOver labels, larger-text layout
- [ ] Localization: wire `PoseGuidanceCopy` to real i18n (currently EN strings)
- [ ] Privacy / medical compliance: on-device storage, consent, data handling
      (face data is biometric — review GDPR / medical-data obligations)
- [ ] Error reporting / logging strategy
- [ ] README with setup + device requirements (TrueDepth iPad/iPhone)
- [ ] Package the native Swift as a proper Flutter plugin for clean export
      (channel names already stable; see feature README)
```
