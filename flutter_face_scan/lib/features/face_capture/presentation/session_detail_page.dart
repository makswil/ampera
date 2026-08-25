import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../application/model_generate_service.dart';
import '../application/session_white_balance.dart';
import '../data/arkit_face_tracking_service.dart';
import '../data/bake/expression_sequence_baker.dart';
import '../data/bake/session_baker.dart';
import '../data/scan_storage.dart';
import '../data/session_folder_loader.dart';
import '../domain/entities/capture_actor_mode.dart';
import '../domain/entities/capture_session.dart';
import '../domain/entities/saved_session.dart';
import 'obj_model_viewer_page.dart';
import 'scan_format.dart';

/// Lists files for one saved session; tap opens a preview.
///
/// User / Clinician only see baked `.obj` models.
/// Dev sees the full tree and can rebake without a new capture.
class SessionDetailPage extends StatefulWidget {
  const SessionDetailPage({
    required this.entry,
    required this.appRole,
    super.key,
  });

  final ScanEntry entry;
  final AppRole appRole;

  @override
  State<SessionDetailPage> createState() => _SessionDetailPageState();
}

class _SessionDetailPageState extends State<SessionDetailPage> {
  final ArkitFaceTrackingService _native = ArkitFaceTrackingService();
  final ModelGenerateService _generate = ModelGenerateService.instance;

  List<ScanFileEntry> _files = <ScanFileEntry>[];
  bool _loading = true;
  String? _rebakeNote;
  StreamSubscription<ModelGenerateKind>? _completedSub;

  bool get _isDev => widget.appRole == AppRole.developer;

  @override
  void initState() {
    super.initState();
    _generate.addListener(_onGenerateChanged);
    _completedSub = _generate.completed.listen(_onGenerateCompleted);
    unawaited(_load());
  }

  @override
  void dispose() {
    _generate.removeListener(_onGenerateChanged);
    unawaited(_completedSub?.cancel());
    super.dispose();
  }

  void _onGenerateChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    final String? error = _generate.error;
    if (error != null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Rebake failed: $error')),
      );
      _generate.clearError();
    }
  }

  void _onGenerateCompleted(ModelGenerateKind kind) {
    if (!mounted) {
      return;
    }
    unawaited(() async {
      await _load();
      if (!mounted || !_generate.pendingOpen) {
        return;
      }
      switch (kind) {
        case ModelGenerateKind.expression:
          final ExpressionSequenceBakeResult? baked = _generate.expressionResult;
          _generate.markOpened();
          if (baked != null) {
            await Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => ObjModelViewerPage(
                  objPath: baked.primaryObjPath,
                  title: widget.entry.consumerTitle,
                  subtitle: '${baked.frames.length} frames',
                  sequenceObjPaths: <String>[
                    for (final ExpressionSequenceBakedFrame f in baked.frames)
                      f.objPath,
                  ],
                ),
              ),
            );
          }
        case ModelGenerateKind.session:
          final BakedTexture? baked = _generate.sessionResult;
          _generate.markOpened();
          if (baked != null) {
            await Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => ObjModelViewerPage(
                  objPath: baked.objPath,
                  title: widget.entry.consumerTitle,
                  subtitle: widget.entry.expression.productLabel,
                ),
              ),
            );
          }
      }
    }());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final documents = await getApplicationDocumentsDirectory();
    final ScanStorage storage = ScanStorage(rootDirectory: documents);
    List<ScanFileEntry> files;
    if (_isDev) {
      files = await storage.listFilesRecursive(widget.entry.id);
    } else {
      files = await storage.listFiles(widget.entry.id);
      final String? bakeDir = storage.expressionBakeDirectory(widget.entry.id);
      if (bakeDir != null) {
        final Directory baked = Directory(bakeDir);
        await for (final FileSystemEntity entity
            in baked.list(followLinks: false)) {
          if (entity is! File) {
            continue;
          }
          final String name =
              entity.uri.pathSegments.where((String s) => s.isNotEmpty).last;
          if (!name.toLowerCase().endsWith('.obj')) {
            continue;
          }
          final FileStat stat = await entity.stat();
          files.add(
            ScanFileEntry(
              name: 'expression/baked/$name',
              path: entity.path,
              sizeBytes: stat.size,
              modified: stat.modified,
            ),
          );
        }
      }
      files = files.where((ScanFileEntry f) => f.isObj).toList(growable: false);
    }
    if (!mounted) {
      return;
    }
    final String? seq = storage.expressionSequenceManifest(widget.entry.id);
    final bool multipose =
        SessionFolderLoader.directoryLooksBakeable(Directory(widget.entry.path));
    setState(() {
      _files = files;
      _loading = false;
      if (seq != null) {
        _rebakeNote = 'Expression clip · sequence.json';
      } else if (multipose) {
        _rebakeNote = '4-pose session';
      } else {
        _rebakeNote = null;
      }
    });
  }

  Future<void> _open(ScanFileEntry file) async {
    if (file.isObj) {
      List<String>? sequence;
      if (file.path.contains('/expression/baked/')) {
        final String bakeDir =
            file.path.substring(0, file.path.lastIndexOf('/'));
        sequence = await loadExpressionBakeFramePaths(bakeDir);
      }
      if (!mounted) {
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ObjModelViewerPage(
            objPath: file.path,
            title: widget.entry.consumerTitle,
            subtitle: widget.entry.expression.productLabel,
            sequenceObjPaths: sequence,
          ),
        ),
      );
      return;
    }
    await _native.dismissPresented();
    await _native.previewFile(file.path);
  }

  Future<void> _rebake() async {
    if (_generate.isRunning) {
      return;
    }
    final documents = await getApplicationDocumentsDirectory();
    final ScanStorage storage = ScanStorage(rootDirectory: documents);
    final String? seq = storage.expressionSequenceManifest(widget.entry.id);

    Future<WhiteBalanceCorrection?> wb({
      required List<Uint8List> jpegs,
      required bool matchFrontal,
      required double targetKelvin,
    }) async {
      final result = await _native.correctWhiteBalance(
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
    }

    if (seq != null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Rebaking expression clip…')),
      );
      await _generate.generateExpression(
        manifestPath: seq,
        mlWb: false,
        mlWbMatchFrontal: true,
        fillHoles: true,
        correctWhiteBalance: wb,
      );
      return;
    }

    final Directory sessionDir = Directory(widget.entry.path);
    if (!SessionFolderLoader.directoryLooksBakeable(sessionDir)) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing bakeable in this folder')),
      );
      return;
    }
    final ({CaptureSession session, SavedSession saved})? loaded =
        await const SessionFolderLoader().load(sessionDir);
    if (loaded == null) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not load session for rebake')),
      );
      return;
    }
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Rebaking 4-pose session…')),
    );
    await _generate.generateSession(
      session: loaded.session,
      directory: sessionDir,
      mlWb: true,
      mlWbMatchFrontal: true,
      fillHoles: true,
      useChinUp: true,
      viewDependent: true,
      viewBestOnly: false,
      dartColorGain: true,
      bakeNormalMap: false,
      correctWhiteBalance: wb,
    );
  }

  @override
  Widget build(BuildContext context) {
    final bool canRebake = _isDev && _rebakeNote != null && !_generate.isRunning;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry.title),
        actions: <Widget>[
          if (_isDev && _rebakeNote != null)
            TextButton.icon(
              onPressed: canRebake ? () => unawaited(_rebake()) : null,
              icon: _generate.isRunning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              label: Text(_generate.isRunning ? 'Baking…' : 'Rebake'),
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _files.isEmpty
          ? Center(
              child: Text(
                _isDev
                    ? 'No files in this session'
                    : 'No baked 3D model yet',
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                if (_isDev && _rebakeNote != null)
                  Material(
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                      child: Text(
                        _generate.isRunning
                            ? 'Rebaking… keep the app open'
                            : 'Dev · $_rebakeNote · Rebake uses current bake defaults',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ),
                  ),
                Expanded(
                  child: ListView.separated(
                    itemCount: _files.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (BuildContext context, int index) {
                      final ScanFileEntry file = _files[index];
                      return ListTile(
                        leading: Icon(_iconFor(file)),
                        title: Text(
                          file.name,
                          style: const TextStyle(fontFamily: 'monospace'),
                        ),
                        subtitle: Text(
                          '${ScanFormat.size(file.sizeBytes)} · '
                          '${ScanFormat.date(file.modified)}',
                        ),
                        trailing: const Icon(Icons.visibility_outlined),
                        onTap: () => unawaited(_open(file)),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }

  static IconData _iconFor(ScanFileEntry file) {
    switch (file.extension) {
      case 'obj':
        return Icons.view_in_ar_outlined;
      case 'mtl':
        return Icons.palette_outlined;
      case 'png':
      case 'jpg':
      case 'jpeg':
        return Icons.image_outlined;
      case 'ply':
        return Icons.grid_on_outlined;
      case 'json':
        return Icons.description_outlined;
      case 'verts':
        return Icons.hub_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}
