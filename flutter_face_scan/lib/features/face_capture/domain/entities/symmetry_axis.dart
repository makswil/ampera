import 'package:equatable/equatable.dart';
import 'package:vector_math/vector_math_64.dart';

/// The fitted mid-sagittal symmetry axis of the face for a single frame.
///
/// Produced by a `SymmetryAxisExtractor` from the raw forehead→chin vertices.
/// Carries the geometric primitives downstream logic needs without exposing the
/// raw vertex buffer.
final class SymmetryAxis extends Equatable {
  const SymmetryAxis({
    required this.origin,
    required this.direction,
    required this.tiltDegrees,
    required this.residual,
    required this.sampleCount,
  });

  /// Mean position of the axis vertices (its centroid), in face-anchor space.
  final Vector3 origin;

  /// Unit direction of the best-fit line, oriented forehead → chin.
  final Vector3 direction;

  /// In-plane tilt of the axis away from screen-vertical, in degrees.
  /// 0 = perfectly upright; sign follows the roll convention.
  final double tiltDegrees;

  /// Mean orthogonal distance of vertices from the fitted line (fit quality;
  /// lower is better). Units match the source vertices (metres in ARKit).
  final double residual;

  /// Number of vertices that contributed to the fit.
  final int sampleCount;

  @override
  List<Object?> get props => <Object?>[
    origin,
    direction,
    tiltDegrees,
    residual,
    sampleCount,
  ];
}
