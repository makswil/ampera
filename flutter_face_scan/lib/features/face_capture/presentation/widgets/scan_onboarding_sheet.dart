import 'package:flutter/material.dart';

import '../../domain/entities/capture_actor_mode.dart';
import '../scan_theme.dart';

/// First-time / help dialog for the scan flow.
Future<bool?> showScanOnboardingSheet(
  BuildContext context, {
  required VoidCallback onStart,
  bool showStartButton = true,
  CaptureActorMode actorMode = CaptureActorMode.user,
}) {
  return showGeneralDialog<bool>(
    context: context,
    useRootNavigator: true,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black.withValues(alpha: 0.72),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (
      BuildContext dialogContext,
      Animation<double> animation,
      Animation<double> secondaryAnimation,
    ) {
      final Brightness brightness = Theme.of(dialogContext).brightness;
      final Color onSurface =
          Theme.of(dialogContext).colorScheme.onSurface;
      final Color muted = onSurface.withValues(alpha: 0.70);
      return SafeArea(
        child: Center(
          child: FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.94, end: 1).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    margin: const EdgeInsets.symmetric(horizontal: 28),
                    padding: const EdgeInsets.fromLTRB(32, 36, 32, 32),
                    decoration: ScanTheme.dialogSurface(brightness),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Icon(Icons.face_retouching_natural,
                            color: ScanTheme.accent, size: 36),
                        const SizedBox(height: 14),
                        Text(
                          actorMode == CaptureActorMode.practitioner
                              ? 'Clinician scan'
                              : 'How to scan',
                          style: Theme.of(dialogContext)
                              .textTheme
                              .titleLarge
                              ?.copyWith(
                                color: onSurface,
                                fontWeight: FontWeight.w600,
                              ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        if (actorMode == CaptureActorMode.practitioner) ...<Widget>[
                          _Bullet(
                            icon: Icons.filter_4,
                            text:
                                '4 angles — front, left, right, under the chin.',
                            muted: muted,
                          ),
                          _Bullet(
                            icon: Icons.tablet_mac,
                            text:
                                'You move the iPad. Patient keeps still.',
                            muted: muted,
                          ),
                          _Bullet(
                            icon: Icons.timer_outlined,
                            text:
                                'Hold each angle ~2–3 seconds when it turns green.',
                            muted: muted,
                          ),
                        ] else ...<Widget>[
                          _Bullet(
                            icon: Icons.filter_4,
                            text:
                                '4 angles — front, left, right, chin up.',
                            muted: muted,
                          ),
                          _Bullet(
                            icon: Icons.timer_outlined,
                            text:
                                'Hold still ~2–3 seconds at each angle.',
                            muted: muted,
                          ),
                          _Bullet(
                            icon: Icons.wb_sunny_outlined,
                            text:
                                'Face in the outline, good light. Glasses off if you can.',
                            muted: muted,
                          ),
                        ],
                        const SizedBox(height: 28),
                        if (showStartButton)
                          FilledButton(
                            style: ScanTheme.primaryButton,
                            onPressed: () {
                              Navigator.of(dialogContext).pop(true);
                              onStart();
                            },
                            child: const Text('Start scan'),
                          )
                        else
                          FilledButton(
                            style: ScanTheme.primaryButton,
                            onPressed: () =>
                                Navigator.of(dialogContext).pop(true),
                            child: const Text('Got it'),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _Bullet extends StatelessWidget {
  const _Bullet({
    required this.icon,
    required this.text,
    required this.muted,
  });

  final IconData icon;
  final String text;
  final Color muted;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: ScanTheme.accent, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: muted,
                fontSize: 15,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Classifies tracking failures for friendly error UI.
enum ScanErrorKind {
  unsupported,
  permission,
  generic,
}

ScanErrorKind classifyScanError(String? message) {
  final String m = (message ?? '').toLowerCase();
  if (m.contains('unsupported') || m.contains('truedepth')) {
    return ScanErrorKind.unsupported;
  }
  if (m.contains('permission') ||
      m.contains('not authorized') ||
      m.contains('denied') ||
      m.contains('access')) {
    return ScanErrorKind.permission;
  }
  return ScanErrorKind.generic;
}

String scanErrorTitle(ScanErrorKind kind) {
  return switch (kind) {
    ScanErrorKind.unsupported => "Face scanning isn't available",
    ScanErrorKind.permission => 'Camera access needed',
    ScanErrorKind.generic => 'Something went wrong',
  };
}

String scanErrorBody(ScanErrorKind kind, String? raw) {
  return switch (kind) {
    ScanErrorKind.unsupported =>
      "This device doesn't have a TrueDepth camera, which is required for face scanning.",
    ScanErrorKind.permission =>
      'Allow camera access in Settings so we can scan your face.',
    ScanErrorKind.generic =>
      raw?.isNotEmpty == true ? raw! : 'Please try again.',
  };
}
