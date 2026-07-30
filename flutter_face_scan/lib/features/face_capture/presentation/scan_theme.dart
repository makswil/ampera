import 'package:flutter/material.dart';

/// Shared scan UI tokens and Material themes.
abstract final class ScanTheme {
  const ScanTheme._();

  /// Teal accent `hsla(188.99, 86.61%, 46.86%, 1)`.
  static final Color accent =
      const HSLColor.fromAHSL(1, 188.99, 0.8661, 0.4686).toColor();

  /// Guidance / chrome drawn over the live camera feed (always light-on-video).
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xB3FFFFFF);

  static const BorderRadius _sharp = BorderRadius.zero;

  static ThemeData light() {
    final ColorScheme scheme = ColorScheme.light(
      primary: accent,
      secondary: accent,
      surface: const Color(0xFFF2F2F7),
      onSurface: const Color(0xFF1C1C1E),
    );
    return _base(brightness: Brightness.light, scheme: scheme);
  }

  static ThemeData dark() {
    final ColorScheme scheme = ColorScheme.dark(
      primary: accent,
      secondary: accent,
      surface: const Color(0xFF0A0A0A),
      onSurface: Colors.white,
    );
    return _base(brightness: Brightness.dark, scheme: scheme);
  }

  static ThemeData _base({
    required Brightness brightness,
    required ColorScheme scheme,
  }) {
    final bool dark = brightness == Brightness.dark;
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      filledButtonTheme: FilledButtonThemeData(style: primaryButton),
      dialogTheme: const DialogThemeData(
        shape: RoundedRectangleBorder(borderRadius: _sharp),
        surfaceTintColor: Colors.transparent,
      ),
      cardTheme: const CardThemeData(
        shape: RoundedRectangleBorder(borderRadius: _sharp),
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      appBarTheme: AppBarTheme(
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        shape: Border(
          bottom: BorderSide(
            color: scheme.onSurface.withValues(alpha: dark ? 0.14 : 0.10),
          ),
        ),
      ),
      listTileTheme: const ListTileThemeData(
        shape: RoundedRectangleBorder(borderRadius: _sharp),
      ),
    );
  }

  static BoxDecoration dialogSurface(Brightness brightness) {
    final bool dark = brightness == Brightness.dark;
    return BoxDecoration(
      color: dark ? const Color(0xFF1C1C1E) : Colors.white,
      border: Border.all(
        color: dark
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.black.withValues(alpha: 0.08),
      ),
      // Explicitly square — no Material soft-radius bleed.
      borderRadius: _sharp,
      boxShadow: <BoxShadow>[
        BoxShadow(
          color: accent.withValues(alpha: dark ? 0.16 : 0.12),
          blurRadius: 32,
        ),
      ],
    );
  }

  static ButtonStyle get primaryButton => FilledButton.styleFrom(
        backgroundColor: accent,
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
        shape: const RoundedRectangleBorder(borderRadius: _sharp),
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
