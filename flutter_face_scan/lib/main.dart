import 'package:flutter/material.dart';

import 'features/face_capture/presentation/capture_page.dart';
import 'features/face_capture/presentation/scan_theme.dart';
import 'features/face_capture/presentation/theme_settings.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final ThemeSettings themeSettings = ThemeSettings();
  await themeSettings.load();
  runApp(FaceScanApp(themeSettings: themeSettings));
}

class FaceScanApp extends StatelessWidget {
  const FaceScanApp({required this.themeSettings, super.key});

  final ThemeSettings themeSettings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: themeSettings,
      builder: (BuildContext context, Widget? _) => MaterialApp(
        title: 'Face Scan',
        theme: ScanTheme.light(),
        darkTheme: ScanTheme.dark(),
        themeMode: themeSettings.mode,
        debugShowCheckedModeBanner: false,
        home: CapturePage(themeSettings: themeSettings),
      ),
    );
  }
}
