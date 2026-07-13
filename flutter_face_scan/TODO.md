# TODO — flutter_face_scan

## Deferred

- **Higher-resolution source photo.** The bake's detail ceiling is the ARKit video
  frame (~1–2 MP), not the texture size. Options, best first:
  1. `ARSession.captureHighResolutionFrame` (iOS 16+): grab a hi-res still mid-
     session, mesh stays synced. Only if a `videoFormat` reports
     `isRecommendedForHighResolutionFrameCapturing` — may be unsupported for
     `ARFaceTrackingConfiguration`; needs on-device check.
  2. Separate `AVCapturePhoto` session: true full-res, but competes with ARKit
     for the camera and loses exact mesh/time sync. Messy.

- **Depth normal map.** Bake a normal/displacement map from the TrueDepth depth
  frame for micro-relief (pores, wrinkles), independent of RGB resolution. Needs
  capturing the depth frame natively. The real fidelity lever.

## Notes

- Texture resolution: 2048 already exceeds the ARKit RGB source; 4096 only
  upsamples. Keep 2048.
