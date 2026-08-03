import 'package:flutter/foundation.dart';

/// Debug-only logger. Silent in profile/release so bake timing never hits
/// production consoles.
void faceScanLog(String message) {
  if (kDebugMode) {
    debugPrint('[face_scan] $message');
  }
}
