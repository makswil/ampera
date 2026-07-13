import 'dart:typed_data';

import 'package:equatable/equatable.dart';
import 'package:vector_math/vector_math_64.dart';

/// One pose's RGB still + the projection mapping a face-local vertex into it,
/// from a single ARKit frame (pixels and matrices agree). See PoseProjection
/// for the projection math.
final class StillCapture extends Equatable {
  const StillCapture({
    required this.bytes,
    required this.width,
    required this.height,
    required this.viewMatrix,
    required this.projectionMatrix,
    required this.faceTransform,
  });

  /// Portrait JPEG bytes.
  final Uint8List bytes;

  /// Pixel dimensions of [bytes].
  final int width;
  final int height;

  /// World → camera (portrait).
  final Matrix4 viewMatrix;

  /// Camera → clip (portrait), built for a viewport of [width]×[height].
  final Matrix4 projectionMatrix;

  /// Face-anchor → world at capture time.
  final Matrix4 faceTransform;

  @override
  List<Object?> get props => <Object?>[
    bytes,
    width,
    height,
    viewMatrix,
    projectionMatrix,
    faceTransform,
  ];
}
