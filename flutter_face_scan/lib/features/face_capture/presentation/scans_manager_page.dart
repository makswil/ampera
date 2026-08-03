import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import '../data/scan_storage.dart';
import '../data/session_folder_loader.dart';
import '../domain/entities/capture_actor_mode.dart';
import 'obj_model_viewer_page.dart';
import 'scan_format.dart';
import 'session_detail_page.dart';

/// Lists saved scan sessions and lets the user open, rename, or delete them.
///
/// When [pickMode] is true, tapping a bakeable session returns its id via
/// [Navigator.pop] (for Prior mesh selection).
///
/// User / Clinician: tap opens the newest bake OBJ viewer directly.
/// Dev: tap opens the raw session file list.
class ScansManagerPage extends StatefulWidget {
  const ScansManagerPage({
    this.pickMode = false,
    this.appRole = AppRole.user,
    super.key,
  });

  /// If true, only bakeable sessions are listed and a tap selects one.
  final bool pickMode;

  /// Gates open behaviour and list chrome (Dev = technical labels + file list).
  final AppRole appRole;

  @override
  State<ScansManagerPage> createState() => _ScansManagerPageState();
}

class _ScansManagerPageState extends State<ScansManagerPage> {
  ScanStorage? _storage;
  List<ScanEntry> _entries = <ScanEntry>[];
  bool _loading = true;

  bool get _isDev => widget.appRole == AppRole.developer;

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

  Future<void> _open(ScanEntry entry) async {
    if (_isDev) {
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => SessionDetailPage(
            entry: entry,
            appRole: widget.appRole,
          ),
        ),
      );
      return;
    }

    final ScanStorage? storage = _storage;
    if (storage == null) {
      return;
    }
    final ScanFileEntry? obj = await storage.newestObj(entry.id);
    if (!mounted) {
      return;
    }
    if (obj == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No 3D model for this scan yet')),
      );
      return;
    }
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => ObjModelViewerPage(
          objPath: obj.path,
          title: entry.consumerTitle,
          subtitle: entry.expression.label,
        ),
      ),
    );
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
        initialName: entry.displayName ?? entry.consumerTitle,
        placeholder: _isDev ? entry.id : 'My scan',
      ),
    );
    if (next == null) {
      return;
    }
    await _storage?.rename(entry.id, next);
    await _load();
  }

  Future<void> _deleteAll() async {
    final bool confirmed = await _confirm(
      _isDev ? 'Delete all scans?' : 'Delete all your scans?',
    );
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

  String _subtitle(ScanEntry entry) {
    if (_isDev) {
      return '${entry.expression.label} · '
          '${ScanFormat.size(entry.sizeBytes)} · '
          '${ScanFormat.date(entry.modified)}'
          '${entry.displayName == null ? '' : ' · ${entry.id}'}';
    }
    return entry.expression.label;
  }

  @override
  Widget build(BuildContext context) {
    final bool pick = widget.pickMode;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          pick
              ? 'Choose mesh scan'
              : (_isDev ? 'Saved scans' : 'Your scans'),
        ),
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
                    : (_isDev ? 'No saved scans' : 'No scans yet'),
              ),
            )
          : ListView.separated(
              itemCount: _entries.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (BuildContext context, int index) {
                final ScanEntry entry = _entries[index];
                return ListTile(
                  leading: pick
                      ? null
                      : Icon(
                          _isDev
                              ? Icons.folder_open_outlined
                              : Icons.view_in_ar_outlined,
                        ),
                  title: Text(_isDev ? entry.title : entry.consumerTitle),
                  subtitle: Text(_subtitle(entry)),
                  onTap: pick
                      ? () => Navigator.pop(context, entry.id)
                      : () => unawaited(_open(entry)),
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
