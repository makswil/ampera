import 'package:flutter/material.dart';

import '../../domain/entities/capture_actor_mode.dart';
import '../../domain/entities/expression_mode.dart';
import '../scan_theme.dart';

/// First-time / help dialog for the scan flow.
Future<bool?> showScanOnboardingSheet(
  BuildContext context, {
  required VoidCallback onStart,
  bool showStartButton = true,
  CaptureActorMode actorMode = CaptureActorMode.user,
  ExpressionMode expression = ExpressionMode.neutral,
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
      final bool smile = expression.isExpressionSequence;
      final bool clinician = actorMode == CaptureActorMode.practitioner;
      return SafeArea(
        child: Center(
          child: FadeTransition(
            opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.94, end: 1).animate(
                CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
              ),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: smile ? 420 : 360,
                ),
                child: Material(
                  color: Colors.transparent,
                  child: Container(
                    margin: EdgeInsets.symmetric(horizontal: smile ? 16 : 28),
                    padding: const EdgeInsets.fromLTRB(32, 36, 32, 32),
                    decoration: ScanTheme.dialogSurface(brightness),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Icon(
                            smile
                                ? Icons.videocam_outlined
                                : Icons.photo_camera_outlined,
                            color: ScanTheme.accent,
                            size: 36),
                        const SizedBox(height: 14),
                        Text(
                          _onboardingTitle(
                            clinician: clinician,
                            smile: smile,
                          ),
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
                        ..._onboardingBullets(
                          clinician: clinician,
                          smile: smile,
                          muted: muted,
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

String _onboardingTitle({required bool clinician, required bool smile}) {
  if (smile) {
    return clinician ? 'Clinician expression scan' : 'How to scan an expression';
  }
  return clinician ? 'Clinician scan' : 'How to scan';
}

List<Widget> _onboardingBullets({
  required bool clinician,
  required bool smile,
  required Color muted,
}) {
  if (smile) {
    if (clinician) {
      return <Widget>[
        _Bullet(
          icon: Icons.filter_4,
          text: 'First capture 4 angles',
          detail: 'Front, left, right, chin up',
          muted: muted,
        ),
        _Bullet(
          icon: Icons.tablet_mac,
          text: 'You move the iPad. The patient stays still.',
          muted: muted,
        ),
        _Bullet(
          icon: Icons.videocam_outlined,
          text:
              'Then the patient looks straight, face at rest — after the countdown they change expression slowly until it finishes.',
          muted: muted,
        ),
        _Bullet(
          icon: Icons.visibility_off_outlined,
          text: 'Remove accessories — glasses, hats, earphones.',
          muted: muted,
        ),
      ];
    }
    return <Widget>[
      _Bullet(
        icon: Icons.filter_4,
        text: 'First, hold 4 angles',
        detail: 'Front, left, right, chin up — 2–3 seconds when the outline is green',
        muted: muted,
      ),
      _Bullet(
        icon: Icons.face_outlined,
        text: 'Then look straight — face at rest, no expression yet.',
        muted: muted,
      ),
      _Bullet(
        icon: Icons.videocam_outlined,
        text:
            'After the countdown, change expression slowly until recording ends.',
        muted: muted,
      ),
      _Bullet(
        icon: Icons.visibility_off_outlined,
        text: 'Remove accessories — glasses, hats, earphones.',
        muted: muted,
      ),
    ];
  }
  if (clinician) {
    return <Widget>[
      _Bullet(
        icon: Icons.filter_4,
        text: 'Capture 4 angles',
        detail: 'Front, left, right, chin up',
        muted: muted,
      ),
      _Bullet(
        icon: Icons.tablet_mac,
        text: 'You move the iPad. The patient stays still.',
        muted: muted,
      ),
      _Bullet(
        icon: Icons.timer_outlined,
        text:
            'Hold each angle 2–3 seconds when the outline turns green.',
        muted: muted,
      ),
      _Bullet(
        icon: Icons.visibility_off_outlined,
        text: 'Remove accessories — glasses, hats, earphones.',
        muted: muted,
      ),
    ];
  }
  return <Widget>[
    _Bullet(
      icon: Icons.filter_4,
      text: 'Turn your head to 4 angles',
      detail: 'Front, left, right, chin up',
      muted: muted,
    ),
    _Bullet(
      icon: Icons.timer_outlined,
      text:
          'Hold still 2–3 seconds at each angle when the outline turns green.',
      muted: muted,
    ),
    _Bullet(
      icon: Icons.crop_free,
      text: 'Keep your face in the outline, in good light.',
      muted: muted,
    ),
    _Bullet(
      icon: Icons.visibility_off_outlined,
      text: 'Remove accessories — glasses, hats, earphones.',
      muted: muted,
    ),
  ];
}

class _Bullet extends StatelessWidget {
  const _Bullet({
    required this.icon,
    required this.text,
    required this.muted,
    this.detail,
  });

  final IconData icon;
  final String text;
  final String? detail;
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  text,
                  style: TextStyle(
                    color: muted,
                    fontSize: 15,
                    height: 1.35,
                  ),
                ),
                if (detail != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    detail!,
                    style: TextStyle(
                      color: muted.withValues(alpha: 0.85),
                      fontSize: 14,
                      height: 1.3,
                    ),
                  ),
                ],
              ],
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
