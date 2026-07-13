import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../data/scan_storage.dart';

/// Lists saved scan sessions and lets the user delete them (individually or
/// all) to reclaim storage.
class ScansManagerPage extends StatefulWidget {
  const ScansManagerPage({super.key});

  @override
  State<ScansManagerPage> createState() => _ScansManagerPageState();
}

class _ScansManagerPageState extends State<ScansManagerPage> {
  ScanStorage? _storage;
  List<ScanEntry> _entries = <ScanEntry>[];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final Directory documents = await getApplicationDocumentsDirectory();
    final ScanStorage storage = ScanStorage(rootDirectory: documents);
    final List<ScanEntry> entries = await storage.list();
    if (!mounted) {
      return;
    }
    setState(() {
      _storage = storage;
      _entries = entries;
      _loading = false;
    });
  }

  Future<void> _deleteOne(ScanEntry entry) async {
    await _storage?.delete(entry.id);
    await _load();
  }

  Future<void> _deleteAll() async {
    final bool confirmed = await _confirm('Delete all scans?');
    if (!confirmed) {
      return;
    }
    await _storage?.deleteAll();
    await _load();
  }

  Future<bool> _confirm(String message) async {
    final bool? result = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(message),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved scans'),
        actions: <Widget>[
          IconButton(
            tooltip: 'Delete all',
            onPressed: _entries.isEmpty ? null : _deleteAll,
            icon: const Icon(Icons.delete_sweep),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
          ? const Center(child: Text('No saved scans'))
          : ListView.separated(
              itemCount: _entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) {
                final ScanEntry entry = _entries[index];
                return ListTile(
                  title: Text(entry.id),
                  subtitle: Text(
                    '${_formatSize(entry.sizeBytes)} · ${_formatDate(entry.modified)}',
                  ),
                  trailing: IconButton(
                    tooltip: 'Delete',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _deleteOne(entry),
                  ),
                );
              },
            ),
    );
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
