import 'dart:async';

import 'package:flutter/services.dart';

import '../../domain/entities/pose_guidance.dart';

/// Sparse haptics + system click for capture milestones (Silent Mode respected).
abstract final class CaptureFeedback {
  const CaptureFeedback._();

  static bool _wasOnTarget = false;

  static void onTargetChanged({required bool onTarget}) {
    if (onTarget && !_wasOnTarget) {
      unawaited(HapticFeedback.lightImpact());
    }
    _wasOnTarget = onTarget;
  }

  static void poseCaptured() {
    unawaited(HapticFeedback.mediumImpact());
    unawaited(SystemSound.play(SystemSoundType.click));
  }

  static void scanCompleted() {
    unawaited(HapticFeedback.heavyImpact());
  }

  static void cancelled() {
    unawaited(HapticFeedback.selectionClick());
  }

  static void reset() {
    _wasOnTarget = false;
  }
}

/// Maps primary [PoseGuidance] to outline cues (turn/tilt → [HeadPoseHint]).
enum GuidanceVisual {
  none,
  center,
  closer,
  farther,
  onTarget,
}

GuidanceVisual visualFor(PoseGuidance? guidance) {
  if (guidance == null) {
    return GuidanceVisual.none;
  }
  return switch (guidance) {
    PoseGuidance.centerFace || PoseGuidance.faceNotDetected =>
      GuidanceVisual.center,
    PoseGuidance.moveCloser => GuidanceVisual.closer,
    PoseGuidance.moveFarther => GuidanceVisual.farther,
    PoseGuidance.onTarget || PoseGuidance.holdSteady => GuidanceVisual.onTarget,
    PoseGuidance.turnLeft ||
    PoseGuidance.turnRight ||
    PoseGuidance.lookUp ||
    PoseGuidance.lookDown ||
    PoseGuidance.levelHead ||
    PoseGuidance.smileMore =>
      GuidanceVisual.none,
  };
}
