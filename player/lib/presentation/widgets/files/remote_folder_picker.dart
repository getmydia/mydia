/// Browse the folders of a connected files backend, one level at a time:
/// an up button that stops at the root, a row for the open folder, and its
/// subfolders. Shared by Add WebDAV and Add SMB.
library;

import 'package:flutter/material.dart';

import '../../../core/sources/files/backend/file_system_backend.dart';
import '../../../core/sources/files/files_accounts.dart';
import '../../../l10n/l10n.dart';

/// Builds one folder row. [onOpen] is null for the open folder's own row, and
/// while a listing is in flight ([busy]).
typedef FolderRowBuilder = Widget Function(
  BuildContext context, {
  required String path,
  required String title,
  required bool busy,
  required VoidCallback? onOpen,
});

class RemoteFolderPicker extends StatefulWidget {
  const RemoteFolderPicker({
    super.key,
    required this.backend,
    required this.root,
    required this.onPicked,
    this.initialFolders,
    this.rowBuilder,
  });

  final FileSystemBackend backend;

  /// The folder the browser starts in and cannot go above.
  final String root;

  /// Called with the open folder's path when its "This folder" row is tapped.
  /// Not called for rows made by a custom [rowBuilder].
  final ValueChanged<String> onPicked;

  /// Entries of [root] the caller already listed, to skip the first listing.
  final List<FileEntry>? initialFolders;

  /// Replaces the default rows, for a caller that decorates them (ticks).
  final FolderRowBuilder? rowBuilder;

  @override
  State<RemoteFolderPicker> createState() => _RemoteFolderPickerState();
}

class _RemoteFolderPickerState extends State<RemoteFolderPicker> {
  late String _dir = trimRootPath(widget.root);
  List<FileEntry> _folders = const [];
  bool _busy = false;
  Object? _failure;
  bool get _failed => _failure != null;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialFolders;
    if (initial != null) {
      _folders = _sortedFolders(initial);
    } else {
      _open(widget.root);
    }
  }

  static List<FileEntry> _sortedFolders(List<FileEntry> entries) => [
        for (final e in entries)
          if (e.isDir && !e.unreadable) e,
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  Future<void> _open(String dir) async {
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      final folders = _sortedFolders(await widget.backend.list(dir));
      if (!mounted) return;
      setState(() {
        _dir = trimRootPath(dir);
        _folders = folders;
      });
    } catch (e) {
      debugPrint('[RemoteFolderPicker] Listing $dir failed: $e');
      if (mounted) setState(() => _failure = e);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _parent(String dir) {
    final trimmed = trimRootPath(dir);
    final i = trimmed.lastIndexOf('/');
    return i <= 0 ? '/' : trimmed.substring(0, i);
  }

  Widget _row(BuildContext context, String path, String title,
      {required bool open}) {
    final onOpen = open && !_busy ? () => _open(path) : null;
    final builder = widget.rowBuilder;
    if (builder != null) {
      return builder(context,
          path: path, title: title, busy: _busy, onOpen: onOpen);
    }
    return ListTile(
      key: ValueKey('folder-picker-row-${trimRootPath(path)}'),
      contentPadding: EdgeInsets.zero,
      leading: open ? const Icon(Icons.folder_outlined) : null,
      title: Text(title),
      onTap: open ? onOpen : (_busy ? null : () => widget.onPicked(_dir)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final atRoot = _dir == trimRootPath(widget.root);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('folder-picker-up'),
              tooltip: l10n.filesPickUp,
              icon: const Icon(Icons.arrow_upward_rounded),
              onPressed: _busy || atRoot ? null : () => _open(_parent(_dir)),
            ),
            Expanded(
              child: Text(_dir,
                  key: const Key('folder-picker-dir'),
                  overflow: TextOverflow.ellipsis),
            ),
          ],
        ),
        if (_failed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
                switch (_failure) {
                  BackendUnauthorized() => l10n.filesPickUnauthorized,
                  BackendNotFound() => l10n.filesSmbNotFound,
                  BackendPermissionLost() => l10n.filesSmbAccessDenied,
                  _ => l10n.filesPickUnreachable,
                },
                key: const Key('folder-picker-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error)),
          ),
        _row(context, _dir, l10n.filesPickThisFolder, open: false),
        const Divider(),
        if (_folders.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(l10n.filesPickNoFolders,
                key: const Key('folder-picker-empty')),
          ),
        for (final f in _folders) _row(context, f.path, f.name, open: true),
      ],
    );
  }
}
