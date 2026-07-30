import 'package:flutter/material.dart';

import 'features/face_capture/presentation/capture_page.dart';
import 'features/face_capture/presentation/scan_theme.dart';

void main() {
  runApp(const FaceScanApp());
}

class FaceScanApp extends StatelessWidget {
  const FaceScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    final Color accent = ScanTheme.accent;
    return MaterialApp(
      title: 'Face Scan',
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.dark(
          primary: accent,
          secondary: accent,
          surface: Colors.black,
        ),
        scaffoldBackgroundColor: Colors.black,
        filledButtonTheme: FilledButtonThemeData(style: ScanTheme.primaryButton),
      ),
      debugShowCheckedModeBanner: false,
      home: const CapturePage(),
    );
  }
}
