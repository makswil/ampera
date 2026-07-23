# TODO — flutter_face_scan

## Hi-res texture via AVCapture (registered) — main feature

Sharp color texture is the biggest visual win. Source photo res is the lever
(depth/normal-map only adds geometric relief, not texture sharpness).

- Front camera **still photo** = 3088×2316 (7 MP). ARKit **face-tracking video**
  = 1440×1080 (1.5 MP). `captureHighResolutionFrame` is NOT offered for face
  tracking (HUD `hi-res cap: no`) → only path is a separate AVCapture session.

**Approach:** during the 2.5s hold (head stable, cancel-on-movement already
guards drift), grab the ARKit mesh + view/projection matrices, then pause ARKit
→ `AVCapturePhoto` (max res) → resume ARKit.

**Registration:** ARKit's `projectionMatrix` is resolution-independent (encodes
FOV, not pixels). Same lens → same FOV; both 4:3. So project the mesh with
ARKit's `view·projection` and map NDC onto the 7 MP photo grid → sharp registered
texture, no low-res sampling.
- Camera intrinsics are available on-device (`AVCameraCalibrationData`). Use ONLY
  if AVCapture's FOV/crop differs from ARKit's video format (verify on-device).
  If it matches, no correction — just map correctly.
- Optional: align the low-res ARKit frame ↔ hi-res photo only if it actually
  helps; skip otherwise.
- Handle front-camera mirroring / orientation.

**Settings — variant toggle (required):** "Texture source: ARKit video (stable)
| AVCapture hi-res". Lets the user switch back to the working ARKit path by one
tap if the AVCapture variant misbehaves — app stays usable.

**Risks:** camera-switch preview freeze (~100s ms) at capture; FOV/crop mismatch;
ARKit resume continuity between poses.

**Status (implemented):** AVCapture hi-res path live behind the Settings toggle.
Native pre-warms the photo camera at scan start (no first-shot freeze) and waits
for AE/AWB to converge before the shot (no cold "night-blue" cast). The photo is
oriented `.right` + horizontally flipped to match ARKit's `capturedImage`
convention (moles land on the correct side; side-pose samples stay on-face).

**Follow-up (later, not urgent):** nose region still looks slightly warped in the
baked texture. Much improved after the mirror fix; likely residual FOV/crop
difference between ARKit video and the AVCapture photo (check the on-device
`[face_scan] FOV check` log) or normal 2D→3D projection. Revisit once evaluated
on the 3D model; may need intrinsics-based correction.

## Depth normal map — secondary

Normal/displacement map from the TrueDepth depth frame for geometric relief
(meso-structure). Depth sensor is coarse → no fine pores; complements the photo,
not a sharpness replacement. Needs capturing the depth frame natively.

## Notes

- Texture resolution is always source/original (both < 4096); the manual
  resolution setting was removed. ARKit video 1.5 MP and the 7 MP photo both fit
  a 4096² atlas.
