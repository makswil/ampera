import 'dart:typed_data';

import '../application/model_generate_service.dart';
import '../application/session_white_balance.dart';
import '../data/arkit_face_tracking_service.dart';

/// Adapts the native ml-wb channel result into [ModelGenerateWbCorrector].
ModelGenerateWbCorrector modelGenerateWbCorrector(
  Future<WhiteBalanceResult?> Function({
    required List<Uint8List> jpegs,
    required bool matchFrontal,
    required double targetKelvin,
  }) native,
) {
  return ({
    required List<Uint8List> jpegs,
    required bool matchFrontal,
    required double targetKelvin,
  }) async {
    final WhiteBalanceResult? result = await native(
      jpegs: jpegs,
      matchFrontal: matchFrontal,
      targetKelvin: targetKelvin,
    );
    if (result == null) {
      return null;
    }
    return WhiteBalanceCorrection(
      ok: result.ok,
      jpegs: result.jpegs,
      targetKelvin: result.targetKelvin,
      error: result.error,
      timingSummary: result.timingSummary,
    );
  };
}
