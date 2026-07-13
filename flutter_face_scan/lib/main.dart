import 'package:flutter/material.dart';

import 'features/face_capture/presentation/capture_page.dart';

void main() {
  runApp(const FaceScanApp());
}

class FaceScanApp extends StatelessWidget {
  const FaceScanApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Face Scan',
      theme: ThemeData.dark(useMaterial3: true),
      debugShowCheckedModeBanner: false,
      home: const CapturePage(),
    );
  }
}
