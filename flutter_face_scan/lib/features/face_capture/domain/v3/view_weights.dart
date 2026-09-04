import 'dart:math' as math;

import 'package:vector_math/vector_math_64.dart';

/// View-dependent (normal-based) texture weighting.
///
/// Replaces the static region tables (`sideWeight`/`downWeight`) with a per-
/// vertex, per-pose weight = how head-on that pose's camera saw the surface
/// (`n·v`). All maths is in WORLD space, consistent per pose:
///
///   worldP   = faceTransform · v
///   camPos   = inverse(viewMatrix) · 0
///   viewDir  = normalize(camPos − worldP)
///   nWorld   = normalize(rot3x3(faceTransform) · nLocal)
///   facing   = dot(nWorld, viewDir)
///   weight   = clamp(facing, 0, 1)^k          (0 if guarded off / grazing)
///
/// The topology is constant across poses, so `nLocal` is computed once from the
/// frontal vertices and merely re-rotated per pose. Pure/testable.

/// Default sharpening exponent (`k`) for the facing weight. Higher = the most
/// head-on pose dominates more strongly (k≈2..4).
const double kDefaultFacingExponent = 3;

/// Default minimum facing (`n·v`) below which a sample is discarded (grazing,
/// stretched samples). `cos(78°) ≈ 0.21` — the surface is nearly edge-on.
const double kDefaultMinFacing = 0.2;

/// Minimum raw `n·v` to treat a clip sample as **good** (sharp enough to keep).
/// `cos(60°) = 0.50`. Between [kDefaultMinFacing] and this the clip still sees
/// the point, but at a grazing angle that smears albedo (**poor**) — the grey
/// stripe at the clip↔L/R join when the threshold was 0.42 (`cos 65°`).
const double kFacingGoodMin = 0.50;

/// Discrete clip-visibility band from raw `n·v` (not the cubed bake weight).
enum FacingQuality {
  /// `n·v` < [kDefaultMinFacing] — backface or ~78°+ from head-on. Clip is blind.
  unseen,

  /// [kDefaultMinFacing] ≤ `n·v` < [kFacingGoodMin] — clip sees it stretched.
  poor,

  /// `n·v` ≥ [kFacingGoodMin] — clip sees it head-on enough; sides should stay out.
  good,
}

FacingQuality facingQuality(double nDotV) {
  if (nDotV < kDefaultMinFacing) {
    return FacingQuality.unseen;
  }
  if (nDotV < kFacingGoodMin) {
    return FacingQuality.poor;
  }
  return FacingQuality.good;
}

/// Where a support still should fill when the clip is not [FacingQuality.good].
enum FacingFillHint {
  clip,
  left,
  right,
  chinUp,
  none,
}

/// Clip keeps the vertex when it is good. Otherwise a support still wins
/// only if its `n·v` is **strictly higher** than the clip and ≥
/// [kDefaultMinFacing]. A worse or equal side (e.g. clip 0.35, side 0.30)
/// stays clip. [none] only when the clip is also below min-facing and no
/// support beats it.
FacingFillHint facingFillHint({
  required double frontal,
  double left = 0,
  double right = 0,
  double chinUp = 0,
}) {
  if (frontal >= kFacingGoodMin) {
    return FacingFillHint.clip;
  }
  FacingFillHint hint = frontal >= kDefaultMinFacing
      ? FacingFillHint.clip
      : FacingFillHint.none;
  double best = frontal;
  void consider(double nv, FacingFillHint h) {
    if (nv >= kDefaultMinFacing && nv > best) {
      best = nv;
      hint = h;
    }
  }

  consider(left, FacingFillHint.left);
  consider(right, FacingFillHint.right);
  consider(chinUp, FacingFillHint.chinUp);
  return hint;
}

/// Argmax of raw `n·v` across clip / L / R / chin-up. Unlike [facingFillHint]
/// this does **not** prefer the clip when it is merely "good" — a side still
/// with a higher facing wins. Values below [kDefaultMinFacing] do not compete;
/// if none clear that bar the hint is [FacingFillHint.none].
FacingFillHint facingBestView({
  required double frontal,
  double left = 0,
  double right = 0,
  double chinUp = 0,
}) {
  FacingFillHint hint = FacingFillHint.none;
  double best = -1;
  void consider(double nv, FacingFillHint h) {
    if (nv >= kDefaultMinFacing && nv > best) {
      best = nv;
      hint = h;
    }
  }

  consider(frontal, FacingFillHint.clip);
  consider(left, FacingFillHint.left);
  consider(right, FacingFillHint.right);
  consider(chinUp, FacingFillHint.chinUp);
  return hint;
}

/// Fraction of the half-width that the frontal pose is allowed to cover on each
/// side of the midline. `0.5` ⇒ the middle 50% of the full face width (the outer
/// 25% on each side is left to the turn poses, which see it head-on).
const double kFrontalCenterFraction = 0.5;

/// Which spatial half/region a pose is allowed to source colour from. Enforced
/// as a hard mask on top of the `n·v` weight so a pose never bleeds across the
/// symmetry axis (no "second nose", no cross-talk), regardless of the numbers —
/// those areas are not reliably visible in that pose in practice.
enum PoseGuard {
  /// Frontal: only the central [kFrontalCenterFraction] band around the midline.
  frontalCenter,

  /// Turn-left pose (sees the face's right half → positive local X).
  rightHalf,

  /// Turn-right pose (sees the face's left half → negative local X).
  leftHalf,

  /// Chin-up pose: only the lower half (below the horizontal axis).
  lowerHalf,

  /// No spatial restriction.
  none,
}

/// Reference frame for the spatial guards, derived ONCE from the face-local
/// frontal vertices (topology is constant across poses).
final class FaceGuardFrame {
  const FaceGuardFrame({
    required this.midlineX,
    required this.halfSpan,
    required this.midY,
  });

  /// Mean local X of the symmetry-axis vertices (robust face centre).
  final double midlineX;

  /// Furthest vertex distance from the midline along X (reference half-width).
  final double halfSpan;

  /// Mean local Y of the horizontal-axis vertices (upper/lower boundary).
  final double midY;
}

/// Builds a [FaceGuardFrame] from face-local [verts] using the symmetry- and
/// horizontal-axis vertex index lists.
FaceGuardFrame computeGuardFrame({
  required List<Vector3> verts,
  required List<int> symmetryAxis,
  required List<int> horizontalAxis,
}) {
  double sx = 0;
  int nx = 0;
  for (final int i in symmetryAxis) {
    if (i >= 0 && i < verts.length) {
      sx += verts[i].x;
      nx++;
    }
  }
  final double midlineX = nx == 0 ? 0 : sx / nx;

  double halfSpan = 0;
  for (final Vector3 v in verts) {
    final double d = (v.x - midlineX).abs();
    if (d > halfSpan) {
      halfSpan = d;
    }
  }

  double sy = 0;
  int ny = 0;
  for (final int i in horizontalAxis) {
    if (i >= 0 && i < verts.length) {
      sy += verts[i].y;
      ny++;
    }
  }
  final double midY = ny == 0 ? 0 : sy / ny;

  return FaceGuardFrame(midlineX: midlineX, halfSpan: halfSpan, midY: midY);
}

/// Per-vertex boolean "allowed to source from this pose" mask for [guard].
List<bool> poseAllowMask({
  required List<Vector3> verts,
  required FaceGuardFrame frame,
  required PoseGuard guard,
  double frontalCenterFraction = kFrontalCenterFraction,
}) {
  final List<bool> out =
      List<bool>.filled(verts.length, guard == PoseGuard.none);
  if (guard == PoseGuard.none) {
    return out;
  }
  final double centerHalf = frame.halfSpan * frontalCenterFraction;
  for (int i = 0; i < verts.length; i++) {
    final double dx = verts[i].x - frame.midlineX;
    switch (guard) {
      case PoseGuard.frontalCenter:
        out[i] = dx.abs() <= centerHalf;
      case PoseGuard.rightHalf:
        out[i] = dx >= 0;
      case PoseGuard.leftHalf:
        out[i] = dx <= 0;
      case PoseGuard.lowerHalf:
        out[i] = verts[i].y <= frame.midY;
      case PoseGuard.none:
        break;
    }
  }
  return out;
}

/// Raw per-vertex `n·v` (cosine of the angle between surface normal and view).
/// `1` = head-on, `0` = 90° grazing, negative = backface. No min-facing gate
/// and no exponent — use this for coverage debug maps.
List<double> viewFacingCosine({
  required List<Vector3> faceLocalVerts,
  required List<Vector3> localNormals,
  required Matrix4 viewMatrix,
  required Matrix4 faceTransform,
}) {
  final int n = faceLocalVerts.length;
  final List<double> out = List<double>.filled(n, 0);

  // Camera world position = translation of the inverted view matrix.
  final Vector3 camPos = (viewMatrix.clone()..invert()).getTranslation();
  // faceTransform is rigid → its 3×3 rotation maps local normals to world.
  final Matrix3 rot = faceTransform.getRotation();

  for (int i = 0; i < n; i++) {
    if (i >= localNormals.length) {
      continue;
    }
    final Vector3 worldP = faceTransform.transformed3(faceLocalVerts[i]);
    final Vector3 viewDir = camPos - worldP;
    if (viewDir.length2 == 0) {
      continue;
    }
    viewDir.normalize();

    final Vector3 nWorld = rot.transformed(localNormals[i]);
    if (nWorld.length2 == 0) {
      continue;
    }
    nWorld.normalize();

    out[i] = nWorld.dot(viewDir);
  }
  return out;
}

/// Per-vertex facing weight for one pose: `clamp(n·v, 0, 1)^exponent`, or 0 when
/// the vertex is guarded off ([allowed] false) or grazing below [minFacing].
///
/// [faceLocalVerts] are this pose's own face-local vertices; [localNormals] are
/// the canonical (frontal) face-local normals, index-aligned. Both include any
/// appended cap-centroid vertices. [viewMatrix]/[faceTransform] are this pose's
/// matrices (column-major, `vector_math_64`).
List<double> viewFacingWeights({
  required List<Vector3> faceLocalVerts,
  required List<Vector3> localNormals,
  required Matrix4 viewMatrix,
  required Matrix4 faceTransform,
  required List<bool> allowed,
  double exponent = kDefaultFacingExponent,
  double minFacing = kDefaultMinFacing,
}) {
  final List<double> nv = viewFacingCosine(
    faceLocalVerts: faceLocalVerts,
    localNormals: localNormals,
    viewMatrix: viewMatrix,
    faceTransform: faceTransform,
  );
  final int n = nv.length;
  final List<double> out = List<double>.filled(n, 0);
  for (int i = 0; i < n; i++) {
    if (i < allowed.length && !allowed[i]) {
      continue;
    }
    final double facing = nv[i];
    if (facing < minFacing) {
      continue;
    }
    final double c = facing.clamp(0.0, 1.0);
    out[i] = exponent == 1 ? c : math.pow(c, exponent).toDouble();
  }
  return out;
}
