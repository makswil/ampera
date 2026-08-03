# Native face-tracking (on-device)

All TrueDepth / rear / ml-wb native code currently lives in
[`AppDelegate.swift`](../AppDelegate.swift) **on purpose**: that file is already
in the Runner Xcode target, so no extra "Target Membership" step is needed for
this prototype husk.

## MARK map (split guide for the host app)

When lifting into the real app, cut `AppDelegate.swift` along these seams and
add each file to the host target's Compile Sources:

| MARK / type | Suggested file |
| --- | --- |
| `FaceTrackingPlugin` | `FaceTrackingPlugin.swift` |
| `FaceTrackingManager` + `PhotoCaptureDelegate` | `FaceTrackingManager.swift` |
| `FacePreviewFactory` / `FacePreviewView` | `FacePreviewFactory.swift` |
| Share helpers (`faceScanPresentShare*`) | `FaceScanShare.swift` |
| `RearCaptureManager` + rear preview types | `RearCaptureManager.swift` |
| `MLWhiteBalanceCorrector` | `MLWhiteBalanceCorrector.swift` |
| `faceScanDebugLog` | `FaceScanLog.swift` (or shared util) |

Keep `AppDelegate` as a thin bootstrap that only registers the plugin.

## Channels (must stay in sync with Dart)

- Method: `flutter_face_scan/face_tracking`
- Event: `flutter_face_scan/face_tracking/frames`
- View: `flutter_face_scan/face_preview`
- Rear equivalents: see `RearFaceTrackingService` / `RearCaptureManager`
