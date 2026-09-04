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

/// Explicit eye- and mouth-hole fill topology for ARKit's open apertures.
///
/// Author-provided triangles on existing verts only (no centroid, no rim
/// flatten). Side naming for eyes matches [FaceRegions]: left = negative
/// local X (anatomical left).
abstract final class FaceHoleGeometry {
  const FaceHoleGeometry._();

  /// Left eye (indices 1085–1108), 22 triangles, flat `[a,b,c, …]`.
  static const List<int> leftEyeTriangles = <int>[
    1088, 1089, 1090,
    1088, 1090, 1091,
    1087, 1088, 1091,
    1087, 1091, 1092,
    1086, 1087, 1092,
    1086, 1092, 1093,
    1085, 1086, 1093,
    1085, 1093, 1094,
    1108, 1085, 1094,
    1108, 1094, 1095,
    1107, 1108, 1095,
    1107, 1095, 1096,
    1106, 1107, 1096,
    1106, 1096, 1097,
    1105, 1106, 1097,
    1105, 1097, 1098,
    1104, 1105, 1098,
    1104, 1098, 1099,
    1103, 1104, 1099,
    1103, 1099, 1100,
    1102, 1103, 1100,
    1100, 1101, 1102,
  ];

  /// Right eye (indices 1061–1084), 22 triangles, flat `[a,b,c, …]`.
  static const List<int> rightEyeTriangles = <int>[
    1080, 1081, 1082,
    1079, 1080, 1082,
    1079, 1082, 1083,
    1078, 1079, 1083,
    1078, 1083, 1084,
    1077, 1078, 1084,
    1061, 1077, 1084,
    1061, 1076, 1077,
    1061, 1062, 1076,
    1062, 1075, 1076,
    1062, 1063, 1075,
    1063, 1074, 1075,
    1063, 1064, 1074,
    1064, 1073, 1074,
    1064, 1065, 1073,
    1065, 1072, 1073,
    1065, 1066, 1072,
    1066, 1071, 1072,
    1066, 1067, 1071,
    1067, 1070, 1071,
    1067, 1068, 1070,
    1068, 1069, 1070,
  ];

  /// Both eyes concatenated (left then right).
  static const List<int> eyeTriangles = <int>[
    ...leftEyeTriangles,
    ...rightEyeTriangles,
  ];

  /// Unique verts on the eye apertures (rims + caps).
  static final Set<int> eyeVertexIndices = Set<int>.unmodifiable(eyeTriangles);

  /// Brows / brow tails. Forced clip so L/R stills cannot double/offset them.
  /// These verts *are* the clip boundary — do not ring-expand past them.
  /// Adjacent L/R boundary verts may sit on the next vertex.
  static const List<int> browVertexIndices = <int>[
    46, 56, 131, 132, 161, 162, 163, 164, 165, 166, 197, 198, 199, 200, 201,
    207, 209, 210, 211, 219, 220, 224, 225, 226, 227, 228, 229, 230, 231, 232,
    234, 235, 326, 327, 328, 333, 334, 335, 353, 355, 375, 388, 415, 417, 418,
    419, 474, 503, 505, 581, 601, 602, 604, 610, 611, 612, 613, 614, 615, 627,
    646, 647, 648, 649, 650, 657, 658, 659, 660, 662, 663, 664, 665, 669, 670,
    761, 762, 763, 766, 767, 768, 784, 785, 786, 806, 808, 819, 820, 821, 845,
    848, 849, 875, 879, 883, 889, 890, 952, 953, 960, 961, 1017, 1018, 1035,
    1036, 1126, 1127, 1128, 1129, 1130, 1131, 1132, 1133, 1134, 1135, 1136,
    1152, 1153, 1154, 1155, 1156, 1177,
  ];

  /// Outer brow / temple verts forced to the left support still.
  static const List<int> browLeftVertexIndices = <int>[
    178, 390, 456, 457, 458, 459, 463, 465, 466, 468, 469, 470, 471, 472, 473,
    475, 940, 1023,
  ];

  /// Outer brow / temple verts forced to the right support still.
  static const List<int> browRightVertexIndices = <int>[
    885, 886, 891, 896, 897, 898, 899, 1010, 1011, 1027, 1028, 1029, 1030,
    1042, 1043, 1044, 1046,
  ];

  /// Mouth aperture fill, 34 triangles, flat `[a,b,c, …]`.
  static const List<int> mouthTriangles = <int>[
    249, 393, 404,
    250, 393, 404,
    250, 305, 404,
    250, 251, 305,
    251, 248, 305,
    251, 252, 248,
    247, 248, 252,
    252, 253, 247,
    275, 247, 253,
    253, 254, 275,
    254, 275, 290,
    254, 255, 290,
    274, 290, 255,
    255, 256, 274,
    256, 265, 274,
    24, 256, 265,
    24, 25, 265,
    684, 823, 834,
    823, 834, 685,
    685, 834, 740,
    740, 685, 686,
    686, 740, 683,
    686, 687, 683,
    682, 683, 687,
    682, 687, 688,
    682, 710, 688,
    688, 689, 710,
    689, 710, 725,
    725, 689, 690,
    690, 709, 725,
    690, 691, 709,
    691, 709, 700,
    691, 24, 700,
    700, 25, 24,
  ];

  /// Closed mouth rim (first == last). Same verts as [mouthTriangles].
  static const List<int> mouthOutline = <int>[
    823, 685, 686, 687, 688, 689, 690, 691, 24, 256, 255, 254, 253, 252, 251,
    250, 393, 249, 404, 305, 248, 247, 275, 290, 274, 265, 25, 700, 709, 725,
    710, 682, 683, 740, 834, 684, 823,
  ];

  /// Unique verts on the mouth aperture.
  static final Set<int> mouthVertexIndices =
      Set<int>.unmodifiable(mouthOutline);

  /// Eyes + mouth — appended when [fillHoles] is on.
  static const List<int> holeTriangles = <int>[
    ...eyeTriangles,
    ...mouthTriangles,
  ];
}
