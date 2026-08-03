import 'dart:async';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../data/arkit_face_tracking_service.dart';
import '../data/scan_storage.dart';
import '../domain/entities/capture_actor_mode.dart';
import 'obj_model_viewer_page.dart';

/// Lists files for one saved session; tap opens a preview.
///
/// Dev sees every file. User / Clinician only see baked `.obj` models.
/// OBJ opens an in-app Flutter page with an embedded SceneKit `UiKitView`;
/// other types use native Quick Look.
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
  List<ScanFileEntry> _files = <ScanFileEntry>[];
  bool _loading = true;

  bool get _isDev => widget.appRole == AppRole.developer;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final documents = await getApplicationDocumentsDirectory();
    final ScanStorage storage = ScanStorage(rootDirectory: documents);
    List<ScanFileEntry> files = await storage.listFiles(widget.entry.id);
    if (!_isDev) {
      files = files.where((ScanFileEntry f) => f.isObj).toList(growable: false);
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _files = files;
      _loading = false;
    });
  }

  Future<void> _open(ScanFileEntry file) async {
    if (file.isObj) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => ObjModelViewerPage(
            objPath: file.path,
            title: widget.entry.consumerTitle,
            subtitle: widget.entry.expression.label,
          ),
        ),
      );
      return;
    }
    await _native.dismissPresented();
    await _native.previewFile(file.path);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.entry.title),
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
          : ListView.separated(
              itemCount: _files.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) {
                final ScanFileEntry file = _files[index];
                return ListTile(
                  leading: Icon(_iconFor(file)),
                  title: Text(file.name),
                  subtitle: Text(
                    '${_formatSize(file.sizeBytes)} · '
                    '${_formatDate(file.modified)}',
                  ),
                  trailing: const Icon(Icons.visibility_outlined),
                  onTap: () => unawaited(_open(file)),
                );
              },
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
      default:
        return Icons.insert_drive_file_outlined;
    }
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  static String _formatDate(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} ${two(d.hour)}:${two(d.minute)}';
  }
}
