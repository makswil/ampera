import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/bake/expression_sequence_baker.dart';
import '../data/bake/session_baker.dart';
import '../data/session_path.dart';
import '../domain/constants/capture_defaults.dart';
import '../domain/entities/capture_session.dart';
import '../presentation/face_scan_log.dart';
import 'session_white_balance.dart';

/// Kind of in-flight / last finished generate job.
enum ModelGenerateKind { session, expression }

/// White-balance callback signature used by generate jobs.
typedef ModelGenerateWbCorrector = Future<WhiteBalanceCorrection?> Function({
  required List<Uint8List> jpegs,
  required bool matchFrontal,
  required double targetKelvin,
});

/// App-scoped generate queue. Survives leaving CapturePage (pushed routes /
/// returning to idle chrome) so bake keeps running in the foreground isolate.
///
/// Note: true iOS background suspension is out of scope — this covers in-app
/// navigation away from the post-scan / Generate UI.
final class ModelGenerateService extends ChangeNotifier {
  ModelGenerateService._();

  static final ModelGenerateService instance = ModelGenerateService._();

  bool _running = false;
  ModelGenerateKind? _kind;
  String? _error;

  BakedTexture? _sessionResult;
  ExpressionSequenceBakeResult? _expressionResult;

  /// Set when a job finishes successfully while no UI consumed the result yet.
  bool _pendingOpen = false;

  final StreamController<ModelGenerateKind> _completed =
      StreamController<ModelGenerateKind>.broadcast();

  bool get isRunning => _running;
  ModelGenerateKind? get kind => _kind;
  String? get error => _error;
  BakedTexture? get sessionResult => _sessionResult;
  ExpressionSequenceBakeResult? get expressionResult => _expressionResult;
  bool get pendingOpen => _pendingOpen;
  Stream<ModelGenerateKind> get completed => _completed.stream;

  Future<void> generateSession({
    required CaptureSession session,
    required Directory directory,
    required bool mlWb,
    required bool mlWbMatchFrontal,
    required bool fillHoles,
    required bool useChinUp,
    required bool viewDependent,
    required bool viewBestOnly,
    required bool dartColorGain,
    required bool bakeNormalMap,
    required ModelGenerateWbCorrector? correctWhiteBalance,
  }) async {
    if (_running) {
      _error = 'Generate already running';
      notifyListeners();
      return;
    }
    _running = true;
    _kind = ModelGenerateKind.session;
    _error = null;
    _sessionResult = null;
    _pendingOpen = false;
    notifyListeners();

    try {
      CaptureSession bakeSession = session;
      final Stopwatch wall = Stopwatch()..start();
      int? mlWbMs;
      String? mlWbNote;
      if (mlWb && correctWhiteBalance != null) {
        final Stopwatch mlSw = Stopwatch()..start();
        final ({CaptureSession session, String note}) applied =
            await applySessionWhiteBalance(
          session: session,
          matchFrontal: mlWbMatchFrontal,
          targetKelvin: CaptureDefaults.neutralKelvin,
          correct: correctWhiteBalance,
        );
        mlWbMs = mlSw.elapsedMilliseconds;
        bakeSession = applied.session;
        mlWbNote = applied.note;
      }
      final Stopwatch bakeSw = Stopwatch()..start();
      final BakedTexture? baked = await const SessionTextureBaker().bake(
        session: bakeSession,
        directory: directory,
        fillHoles: fillHoles,
        textureSize: 0,
        useChinUp: useChinUp,
        viewDependent: viewDependent,
        viewBlend: !viewBestOnly,
        colorMatch: viewDependent && dartColorGain,
        colorMatchNeutral: false,
        bakeNormalMap: bakeNormalMap,
      );
      final int bakeMs = bakeSw.elapsedMilliseconds;
      wall.stop();
      final String bakeTiming = baked?.timingSummary ?? 'bake ${bakeMs}ms';
      faceScanLog(
        mlWbMs == null
            ? '$bakeTiming · wall ${wall.elapsedMilliseconds}ms'
            : 'ml-wb ${mlWbMs}ms · $bakeTiming · wall ${wall.elapsedMilliseconds}ms'
                '${mlWbNote != null ? ' | $mlWbNote' : ''}',
      );
      _sessionResult = baked;
      if (baked == null) {
        _error = 'Generate produced no model';
      } else {
        _pendingOpen = true;
        _completed.add(ModelGenerateKind.session);
      }
    } on Object catch (e) {
      faceScanLog('Generate failed: $e');
      _error = e.toString();
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  Future<void> generateExpression({
    required String manifestPath,
    required bool mlWb,
    required bool mlWbMatchFrontal,
    required bool fillHoles,
    bool debugSourceColors = false,
    required ModelGenerateWbCorrector? correctWhiteBalance,
  }) async {
    if (_running) {
      _error = 'Generate already running';
      notifyListeners();
      return;
    }
    _running = true;
    _kind = ModelGenerateKind.expression;
    _error = null;
    _expressionResult = null;
    _pendingOpen = false;
    notifyListeners();

    try {
      final Stopwatch wall = Stopwatch()..start();
      Map<String, Uint8List>? jpegOverrides;
      String? mlWbNote;
      int? mlWbMs;

      if (mlWb && correctWhiteBalance != null) {
        final Stopwatch mlSw = Stopwatch()..start();
        final ({Map<String, Uint8List>? overrides, String note}) prepared =
            await prepareExpressionMlWb(
          manifestPath: manifestPath,
          matchFrontal: mlWbMatchFrontal,
          correct: correctWhiteBalance,
        );
        mlWbMs = mlSw.elapsedMilliseconds;
        jpegOverrides = prepared.overrides;
        mlWbNote = prepared.note;
      }

      final Stopwatch bakeSw = Stopwatch()..start();
      final ExpressionSequenceBakeResult baked =
          await bakeExpressionSequenceInBackground(
        ExpressionSequenceBakeRequest(
          manifestPath: manifestPath,
          textureSize: 1024,
          fillHoles: fillHoles,
          debugSourceColors: debugSourceColors,
          jpegOverrides: jpegOverrides,
        ),
      );
      final int bakeMs = bakeSw.elapsedMilliseconds;
      wall.stop();
      faceScanLog(
        '${mlWbMs == null ? 'expr-bake ${bakeMs}ms' : 'ml-wb ${mlWbMs}ms · expr-bake ${bakeMs}ms'}'
        ' · wall ${wall.elapsedMilliseconds}ms'
        '${mlWbNote != null ? ' | $mlWbNote' : ''}'
        ' | ${baked.frames.length} frames'
        '${baked.repairedNoseOutliers > 0 ? ' | mesh-fix ${baked.repairedNoseOutliers}' : ''}',
      );
      _expressionResult = baked;
      _pendingOpen = true;
      _completed.add(ModelGenerateKind.expression);
    } on Object catch (e) {
      faceScanLog('Expression generate failed: $e');
      _error = e.toString();
    } finally {
      _running = false;
      notifyListeners();
    }
  }

  /// Marks a successful result as opened by the UI (viewer / share ready).
  void markOpened() {
    if (!_pendingOpen) {
      return;
    }
    _pendingOpen = false;
    notifyListeners();
  }

  void clearError() {
    if (_error == null) {
      return;
    }
    _error = null;
    notifyListeners();
  }
}

/// Runs ml-wb over every expression-frame JPEG; originals on disk stay raw.
Future<({Map<String, Uint8List>? overrides, String note})>
    prepareExpressionMlWb({
  required String manifestPath,
  required bool matchFrontal,
  required ModelGenerateWbCorrector correct,
}) async {
  final File manifestFile = File(manifestPath);
  if (!manifestFile.existsSync()) {
    return (overrides: null, note: 'ml-wb: no manifest');
  }
  final Object? decoded = jsonDecode(await manifestFile.readAsString());
  if (decoded is! Map<String, dynamic>) {
    return (overrides: null, note: 'ml-wb: bad manifest');
  }
  final Directory exprDir = manifestFile.parent;
  final List<dynamic> rawFrames =
      decoded['frames'] as List<dynamic>? ?? const <dynamic>[];
  final List<String> names = <String>[];
  final List<Uint8List> inputs = <Uint8List>[];
  for (final dynamic raw in rawFrames) {
    if (raw is! Map<String, dynamic>) {
      continue;
    }
    final String jpgName = raw['jpg'] as String? ?? '';
    if (jpgName.isEmpty) {
      continue;
    }
    final File? jpgFile = SessionPath.fileUnderRoot(exprDir, jpgName);
    if (jpgFile == null || !jpgFile.existsSync()) {
      continue;
    }
    names.add(jpgName);
    inputs.add(await jpgFile.readAsBytes());
    // Let the Generate spinner paint between disk reads.
    if (inputs.length % 8 == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }
  if (inputs.isEmpty) {
    return (overrides: null, note: 'ml-wb: no frames');
  }

  final WhiteBalanceCorrection? result = await correct(
    jpegs: inputs,
    matchFrontal: matchFrontal,
    targetKelvin: CaptureDefaults.neutralKelvin,
  );
  if (result == null || !result.ok || result.jpegs.length != names.length) {
    return (
      overrides: null,
      note: 'ml-wb FAILED (${result?.error ?? 'no response'}) — raw frames'
          '${result?.timingSummary != null ? ' · ${result!.timingSummary}' : ''}',
    );
  }

  final Map<String, Uint8List> overrides = <String, Uint8List>{
    for (int i = 0; i < names.length; i++) names[i]: result.jpegs[i],
  };
  final String mode =
      matchFrontal ? 'frontal' : '${CaptureDefaults.neutralKelvin.round()} K';
  final String timing =
      result.timingSummary != null ? ' · ${result.timingSummary}' : '';
  return (
    overrides: overrides,
    note: 'ml-wb OK → ${result.targetKelvin.round()} K ($mode) · '
        '${names.length} frames$timing',
  );
}
