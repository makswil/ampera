import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../data/scan_storage.dart';
import '../data/session_folder_loader.dart';

/// Lists saved scan sessions and lets the user delete them (individually or
/// all) to reclaim storage.
///
/// When [pickMode] is true, tapping a bakeable session returns its id via
/// [Navigator.pop] (for Prior mesh selection).
class ScansManagerPage extends StatefulWidget {
  const ScansManagerPage({
    this.pickMode = false,
    super.key,
  });

  /// If true, only bakeable sessions are listed and a tap selects one.
  final bool pickMode;

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
    List<ScanEntry> entries = await storage.list();
    if (widget.pickMode) {
      entries = entries
          .where(
            (ScanEntry e) =>
                SessionFolderLoader.directoryLooksBakeable(Directory(e.path)),
          )
          .toList(growable: false);
    }
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

  Future<void> _rename(ScanEntry entry) async {
    final String? next = await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => _RenameScanDialog(
        initialName: entry.displayName ?? entry.title,
        placeholder: entry.id,
      ),
    );
    if (next == null) {
      return;
    }
    await _storage?.rename(entry.id, next);
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
    final bool pick = widget.pickMode;
    return Scaffold(
      appBar: AppBar(
        title: Text(pick ? 'Choose mesh scan' : 'Saved scans'),
        actions: <Widget>[
          if (!pick)
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
          ? Center(
              child: Text(
                pick
                    ? 'No scans with a bakeable mesh'
                    : 'No saved scans',
              ),
            )
          : ListView.separated(
              itemCount: _entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) {
                final ScanEntry entry = _entries[index];
                return ListTile(
                  title: Text(entry.title),
                  subtitle: Text(
                    '${entry.expression.label} · '
                    '${_formatSize(entry.sizeBytes)} · '
                    '${_formatDate(entry.modified)}'
                    '${entry.displayName == null ? '' : ' · ${entry.id}'}',
                  ),
                  onTap: pick
                      ? () => Navigator.pop(context, entry.id)
                      : null,
                  trailing: pick
                      ? const Icon(Icons.chevron_right)
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            IconButton(
                              tooltip: 'Rename',
                              icon: const Icon(Icons.edit_outlined),
                              onPressed: () => unawaited(_rename(entry)),
                            ),
                            IconButton(
                              tooltip: 'Delete',
                              icon: const Icon(Icons.delete_outline),
                              onPressed: () => unawaited(_deleteOne(entry)),
                            ),
                          ],
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

/// Owns the text controller so keyboard insets / rebuilds don't reset the caret.
class _RenameScanDialog extends StatefulWidget {
  const _RenameScanDialog({
    required this.initialName,
    required this.placeholder,
  });

  final String initialName;
  final String placeholder;

  @override
  State<_RenameScanDialog> createState() => _RenameScanDialogState();
}

class _RenameScanDialogState extends State<_RenameScanDialog> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName);
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _focusNode.requestFocus();
      _controller.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _controller.text.length,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() => Navigator.pop(context, _controller.text);

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename'),
      content: TextField(
        controller: _controller,
        focusNode: _focusNode,
        autofocus: true,
        keyboardType: TextInputType.text,
        textInputAction: TextInputAction.done,
        textCapitalization: TextCapitalization.sentences,
        autocorrect: false,
        enableSuggestions: false,
        smartDashesType: SmartDashesType.disabled,
        smartQuotesType: SmartQuotesType.disabled,
        decoration: InputDecoration(
          hintText: widget.placeholder,
          labelText: 'Name',
          border: const OutlineInputBorder(
            borderRadius: BorderRadius.zero,
          ),
        ),
        onSubmitted: (_) => _submit(),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        TextButton(
          onPressed: _submit,
          child: const Text('Save'),
        ),
      ],
    );
  }
}
