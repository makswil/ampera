import 'package:flutter/material.dart';

import '../scan_theme.dart';

/// First-time / help dialog for the scan flow.
Future<bool?> showScanOnboardingSheet(
  BuildContext context, {
  required VoidCallback onStart,
  bool showStartButton = true,
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
                    decoration: ScanTheme.dialogSurface,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Icon(Icons.face_retouching_natural,
                            color: ScanTheme.accent, size: 36),
                        const SizedBox(height: 14),
                        Text(
                          'How to scan',
                          style: Theme.of(dialogContext)
                              .textTheme
                              .titleLarge
                              ?.copyWith(
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 20),
                        const _Bullet(
                          icon: Icons.filter_4,
                          text:
                              "We'll capture 4 angles — front, left, right, chin up.",
                        ),
                        const _Bullet(
                          icon: Icons.timer_outlined,
                          text:
                              'Hold still for about 2–3 seconds at each angle.',
                        ),
                        const _Bullet(
                          icon: Icons.wb_sunny_outlined,
                          text:
                              'Keep your face in the outline, in good light. Glasses off if you can.',
                        ),
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
  const _Bullet({required this.icon, required this.text});

  final IconData icon;
  final String text;

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
              style: const TextStyle(
                color: ScanTheme.textSecondary,
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
