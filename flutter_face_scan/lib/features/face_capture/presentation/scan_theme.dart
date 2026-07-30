import 'package:flutter/material.dart';

/// Shared scan UI tokens.
abstract final class ScanTheme {
  const ScanTheme._();

  /// Teal accent `hsla(188.99, 86.61%, 46.86%, 1)`.
  static final Color accent =
      const HSLColor.fromAHSL(1, 188.99, 0.8661, 0.4686).toColor();

  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xB3FFFFFF);

  static BoxDecoration get dialogSurface => BoxDecoration(
        color: const Color(0xFF1C1C1E),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: accent.withValues(alpha: 0.16),
            blurRadius: 32,
          ),
        ],
      );

  static ButtonStyle get primaryButton => FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.zero),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
      );

  static TextStyle get guidanceTitle => const TextStyle(
        color: textPrimary,
        fontSize: 22,
        fontWeight: FontWeight.w600,
        height: 1.25,
        letterSpacing: -0.2,
      );

  static TextStyle get guidanceBody => const TextStyle(
        color: textSecondary,
        fontSize: 15,
        height: 1.35,
      );
}
