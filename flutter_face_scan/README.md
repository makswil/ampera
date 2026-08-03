# flutter_face_scan

TrueDepth face capture + UV texture bake for dermatological 3D analysis (iOS).
This repo is a **prototype husk**: the portable unit is
`lib/features/face_capture/` plus the native Swift in `ios/Runner/AppDelegate.swift`.

**Requires:** TrueDepth device (iPhone/iPad). Simulator has no face tracking.

```bash
flutter pub get
flutter run
flutter test
```

---

## Architecture

Layer rule: **domain never imports Flutter or ARKit.**

```
presentation → application → domain ← data
```

| Layer | Role |
| --- | --- |
| `domain/` | Pure Dart entities, validators, bake math (unit-tested) |
| `application/` | BLoC state machine |
| `data/` | Platform channels, file I/O, bake orchestration |
| `presentation/` | UI; renders `CaptureState`, hosts `UiKitView` |

Native TrueDepth / rear / ml-wb live in `AppDelegate.swift` (already in the
Xcode target). Split guide for the host app:
[`ios/Runner/FaceTracking/README.md`](ios/Runner/FaceTracking/README.md).

Why not `arkit_plugin` alone: it does not expose the full `ARFaceGeometry`
vertex buffer (~1220 verts) needed for the symmetry-axis gate and bake.

---

## Export into the host app

1. Copy `lib/features/face_capture/`.
2. Copy native code from `AppDelegate.swift` (cut along MARK sections — see
   FaceTracking README) + `ios/Runner/Models/MLWhiteBalance.mlpackage`.
3. Keep channel names (`flutter_face_scan/face_tracking*`).
4. Deps: `flutter_bloc`, `bloc`, `equatable`, `vector_math`, `image`, `path_provider`.
5. Add `NSCameraUsageDescription` to the host `Info.plist`.
6. Route to `CapturePage`.

File-level map of the feature: [`lib/features/face_capture/README.md`](lib/features/face_capture/README.md).

---

## On-device features (shipped)

- Guided capture: frontal → left → right → chin-up (hold gate + flash feedback)
- Clinician / user roles; front TrueDepth mesh; optional rear photo/video pass
- Session save: PLY + JPEG + `manifest.json` under `Documents/face_scans/`
- Texture bake / Generate 3D (view-dependent `n·v`, eye fill, optional normal map)
- Embedded SceneKit OBJ viewer + share sheet
- ml-wb CoreML white-balance before generate
- Runtime settings (role, distance, model toggles)

---

## Open follow-ups (not blocking export)

- Nose warp residual (possible FOV/intrinsics mismatch AVCapture ↔ ARKit)
- Depth-based normal/displacement map from TrueDepth (meso relief)
- Unsupported-device / permission-denied UX polish
- V3 mesh merge (`ReconstructionDatasetBuilder` still stubbed)
- Host-app packaging: extract Swift into a proper Flutter plugin
- Privacy / medical compliance review (face data is biometric)
