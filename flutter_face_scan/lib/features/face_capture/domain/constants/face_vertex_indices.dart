/// Vertex indices into the ARKit `ARFaceGeometry` vertex buffer (1220 verts).
///
/// These describe the facial **symmetry (mid-sagittal) axis** — the line of
/// vertices running down the centre of the face from forehead to chin.
///
/// NOTE: the ordering below was derived empirically from TrueDepth captures and
/// is marked by the author as "not 100% certain". It is therefore isolated here
/// as a single, well-documented source of truth so it can be revised in exactly
/// one place (and asserted against in tests) without touching any logic.
library;

/// Indices of the mid-sagittal symmetry axis, ordered **top → bottom**
/// (forehead → chin).
///
/// The mouth aperture splits the polyline into an upper segment (forehead down
/// to the upper-lip centre) and a lower segment (lower-lip centre to chin). The
/// gap is intentionally NOT bridged by a vertex — see [foreheadToUpperLip] and
/// [lowerLipToChin].
abstract final class FaceSymmetryAxis {
  const FaceSymmetryAxis._();

  /// Forehead → centre of the upper lip (above the mouth gap).
  static const List<int> foreheadToUpperLip = <int>[
    20,
    956,
    1022,
    1041,
    19,
    18,
    17,
    16,
    15,
    36,
    14,
    13,
    12,
    11,
    10,
    9,
    8,
    7,
    6,
    37,
    5,
    38,
    4,
    3,
    2,
    0,
    1,
    21,
    22,
    23,
    24,
  ];

  /// Centre of the lower lip → chin (below the mouth gap).
  static const List<int> lowerLipToChin = <int>[
    25,
    26,
    27,
    28,
    29,
    30,
    31,
    32,
    33,
    34,
    35,
    975,
    1049,
    1048,
    1047,
  ];

  /// Full ordered axis (upper + lower segments concatenated, top → bottom).
  ///
  /// The mouth gap lies between [foreheadToUpperLip].last (24) and
  /// [lowerLipToChin].first (25).
  static const List<int> ordered = <int>[
    ...foreheadToUpperLip,
    ...lowerLipToChin,
  ];

  /// Topmost reference vertex (forehead).
  static int get foreheadVertex => ordered.first;

  /// Bottommost reference vertex (chin).
  static int get chinVertex => ordered.last;
}

/// A **horizontal** reference axis running across the face (roughly cheek → nose
/// base → cheek), used to split the lower face (under-nose, lips, chin, jaw
/// underside) from the upper face. The bake sources everything below this line
/// from the chin-up ([FacePose.up]) still, which sees those grazing-angle areas
/// head-on instead of stretched.
///
/// Like [FaceSymmetryAxis], the indices were derived empirically from on-device
/// TrueDepth captures — isolated here so they can be revised in one place.
abstract final class FaceHorizontalAxis {
  const FaceHorizontalAxis._();

  /// Indices of the horizontal split line (order is not significant; only the
  /// vertices' mean height is used as the upper/lower boundary).
  static const List<int> ordered = <int>[
    295, 931, 939, 464, 463, 390, 354, 152, 151, 320, 436, 313, 292, 298, 143,
    137, 444, 362, 156, 9, 605, 793, 872, 586, 592, 733, 727, 748, 864, 755,
    600, 601, 785, 821, 1044, 1027, 1008, 1000, 730,
  ];
}
