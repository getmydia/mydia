/// Browse the folders of a connected files backend, one level at a time:
/// an up button that stops at the root, a row for the open folder, and its
/// subfolders. Shared by Add WebDAV and Add SMB.
///
/// It fills the screen below the app bar: the caller's [RemoteFolderPicker.header]
/// scrolls away, the location bar (the way up, the open folder and its own
/// row) stays pinned while the folders scroll under it, and the caller's
/// [RemoteFolderPicker.footer] (the save button) stays below the list.
///
/// Back climbs out of a subfolder before it leaves the setup, abandons a
/// listing still in flight, and leaves once a climb has failed.
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
    this.header = const [],
    this.footer,
    this.busy = false,
    this.problem,
    this.keyPrefix = 'folder-picker',
    this.onExit,
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

  /// Scrolls away above the location bar: the spent form, the instructions.
  final List<Widget> header;

  /// Stays below the folder list, such as the save button.
  final Widget? footer;

  /// The caller is busy (saving): no folder opens, and back neither climbs
  /// nor leaves until it is done. Never abandoned the way a listing is.
  final bool busy;

  /// The caller's own problem, such as a failed save, shown in the location
  /// bar in place of a listing failure.
  final String? problem;

  /// Prefix of the keys of the up button (`-up`), the open folder (`-dir`),
  /// the problem line (`-error`), the empty text (`-empty`) and the scroll
  /// view (`-folder-list`).
  final String keyPrefix;

  /// Called in place of leaving the route when back is pressed at [root]
  /// (or after a failed climb), for a caller with a step of its own before
  /// the picker, such as SMB's share list. Null lets back leave the route.
  final VoidCallback? onExit;

  @override
  State<RemoteFolderPicker> createState() => _RemoteFolderPickerState();
}

class _RemoteFolderPickerState extends State<RemoteFolderPicker> {
  late String _dir = trimRootPath(widget.root);
  List<FileEntry> _folders = const [];
  Object? _failure;

  /// Bumped by every folder listing and by back, so a listing back
  /// abandoned cannot land on top of where the user is now.
  int _listing = 0;

  /// Whether a folder listing is in flight, which back may abandon.
  bool _opening = false;

  /// Whether the last climb to a parent folder failed. Back then leaves,
  /// rather than retrying against a share that stopped answering.
  bool _climbFailed = false;

  /// Whether the open folder has been listed. Until it has, its own row
  /// cannot be picked: a root whose listing failed would be saved as a
  /// library that cannot be read.
  bool _listed = false;

  bool get _busy => _opening || widget.busy;
  String get _root => trimRootPath(widget.root);
  bool get _atRoot => _dir == _root;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialFolders;
    if (initial != null) {
      _folders = _sortedFolders(initial);
      _listed = true;
    } else {
      _open(widget.root);
    }
  }

  /// Whether [path] is [RemoteFolderPicker.root] or below it. A path with a
  /// `.` or `..` segment never is: `/dav/../elsewhere` only looks inside.
  bool _withinRoot(String path) {
    final p = trimRootPath(path);
    if (p.split('/').any((s) => s == '.' || s == '..')) return false;
    final root = _root;
    if (root == '/') return p.startsWith('/');
    return p == root || p.startsWith('$root/');
  }

  /// The readable subfolders, sorted. A server that lists a folder outside
  /// the root (a WebDAV href elsewhere on the host) does not get a row:
  /// opening it would strand back outside the root, where it never stops.
  List<FileEntry> _sortedFolders(List<FileEntry> entries) => [
        for (final e in entries)
          if (e.isDir && !e.unreadable && _withinRoot(e.path)) e,
      ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));

  /// Opens the folder above the current one.
  Future<void> _climb() => _open(_parent(_dir), climb: true);

  /// Lists [dir]. A failed [climb] lets back leave the setup, since the
  /// share has stopped answering on the way out.
  Future<void> _open(String dir, {bool climb = false}) async {
    final listing = ++_listing;
    setState(() {
      _opening = true;
      _failure = null;
      _climbFailed = false;
    });
    bool current() => mounted && listing == _listing;
    try {
      final folders = _sortedFolders(await widget.backend.list(dir));
      if (!current()) return;
      setState(() {
        _dir = trimRootPath(dir);
        _folders = folders;
        _listed = true;
      });
    } catch (e) {
      debugPrint('[RemoteFolderPicker] Listing $dir failed: $e');
      if (current()) {
        setState(() {
          _failure = e;
          _climbFailed = climb;
        });
      }
    } finally {
      if (current()) setState(() => _opening = false);
    }
  }

  String _parent(String dir) {
    final trimmed = trimRootPath(dir);
    final i = trimmed.lastIndexOf('/');
    return i <= 0 ? '/' : trimmed.substring(0, i);
  }

  /// While a folder is still listing, back abandons it: a slow server never
  /// leaves back dead for the length of its timeout. Otherwise it climbs,
  /// or, at the root or after a failed climb, hands over to
  /// [RemoteFolderPicker.onExit] when there is one.
  void _onPop(bool didPop, Object? _) {
    if (didPop) return;
    if (_opening) {
      setState(() {
        _listing++;
        _opening = false;
      });
      return;
    }
    if (_busy) return;
    if (_atRoot || _climbFailed) {
      widget.onExit?.call();
    } else {
      _climb();
    }
  }

  Key _key(String suffix) => Key('${widget.keyPrefix}-$suffix');

  Widget _row(BuildContext context, String path, String title,
      {required bool open}) {
    final onOpen = open && !_busy ? () => _open(path) : null;
    // The open folder's own row waits for its listing.
    final busy = _busy || (!open && !_listed);
    final builder = widget.rowBuilder;
    if (builder != null) {
      return builder(context,
          path: path, title: title, busy: busy, onOpen: onOpen);
    }
    return ListTile(
      key: ValueKey('folder-picker-row-${trimRootPath(path)}'),
      contentPadding: EdgeInsets.zero,
      leading: open ? const Icon(Icons.folder_outlined) : null,
      title: Text(title),
      onTap: open ? onOpen : (busy ? null : () => widget.onPicked(_dir)),
    );
  }

  String? _problemText(AppLocalizations l10n) {
    final problem = widget.problem;
    if (problem != null) return problem;
    final failure = _failure;
    if (failure == null) return null;
    return switch (failure) {
      BackendUnauthorized() => l10n.filesPickUnauthorized,
      BackendNotFound() => l10n.filesSmbNotFound,
      BackendPermissionLost() => l10n.filesSmbAccessDenied,
      _ => l10n.filesPickUnreachable,
    };
  }

  /// Where the list is and the way up, pinned while the folders scroll
  /// under it. Painted opaque so they do not show through, by a [Material]
  /// rather than a ColoredBox so the open folder's row keeps its ink.
  Widget _location(BuildContext context, AppLocalizations l10n) {
    final problem = _problemText(l10n);
    return Material(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                IconButton(
                  key: _key('up'),
                  tooltip: l10n.filesPickUp,
                  icon: const Icon(Icons.arrow_upward_rounded),
                  onPressed: _busy || _atRoot ? null : _climb,
                ),
                Expanded(
                  child: Text(_dir,
                      key: _key('dir'), overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(problem,
                      key: _key('error'),
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error)),
                ),
              ),
            _row(context, _dir, l10n.filesPickThisFolder, open: false),
            const Divider(height: 1),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final footer = widget.footer;
    return PopScope(
      // Never mid-listing (back abandons it) or while the caller is busy.
      // After a failed climb back leaves: a share that stopped answering
      // would otherwise turn every back into another failed climb.
      // With an onExit, back never leaves the route itself.
      canPop: !_busy && widget.onExit == null && (_atRoot || _climbFailed),
      onPopInvokedWithResult: _onPop,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: CustomScrollView(
              key: _key('folder-list'),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                  sliver: SliverList.list(children: widget.header),
                ),
                PinnedHeaderSliver(child: _location(context, l10n)),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  sliver: _folders.isEmpty
                      ? SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(l10n.filesPickNoFolders,
                                key: _key('empty')),
                          ),
                        )
                      : SliverList.builder(
                          itemCount: _folders.length,
                          itemBuilder: (context, i) => _row(
                              context, _folders[i].path, _folders[i].name,
                              open: true),
                        ),
                ),
              ],
            ),
          ),
          if (footer != null)
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
                child: footer,
              ),
            ),
        ],
      ),
    );
  }
}
