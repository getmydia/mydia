/// Connect a WebDAV share as a files library: address, user and password,
/// then the folders to add, each with what it holds.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../../../core/sources/connection/source_connection.dart'
    show isPrivateHost;
import '../../../core/sources/files/backend/file_system_backend.dart';
import '../../../core/sources/files/backend/webdav_backend.dart'
    show webDavDecodePath;
import '../../../core/sources/files/files_account.dart';
import '../../../core/sources/files/files_accounts.dart';
import '../../../core/sources/files/media_names.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/ui/reduced_motion.dart';
import '../../../l10n/l10n.dart';
import '../detail/detail_links.dart';
import '../../widgets/files/experimental_badge.dart';
import 'files_library_kind_picker.dart';
import 'server_url.dart';

enum _Problem { address, httpsRequired, unauthorized, unreachable, save }

class AddWebDavScreen extends ConsumerStatefulWidget {
  const AddWebDavScreen({super.key, this.reauthAccountId});

  /// A saved share to sign in to again: its address is filled in.
  final String? reauthAccountId;

  @override
  ConsumerState<AddWebDavScreen> createState() => _AddWebDavScreenState();
}

class _AddWebDavScreenState extends ConsumerState<AddWebDavScreen> {
  final _url = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  _Problem? _problem;
  bool _busy = false;

  /// Shared by every backend this screen builds, closed with it.
  final _client = http.Client();

  /// Set once the share answered; null while the form is being filled.
  FileSystemBackend? _backend;
  Uri? _base;
  bool _saved = false;
  String _dir = '/';
  List<FileEntry> _folders = const [];
  final _chosen = <String, FilesLibraryKind>{};

  /// The folder instructions, scrolled to the top once the share answers so
  /// the folders, not the spent form, fill a phone screen.
  final _pickFoldersKey = GlobalKey();

  /// How long that scroll takes: resolved in build, zero under reduced
  /// motion.
  Duration _revealDuration = Duration.zero;

  /// Bumped by every folder listing and by back, so a listing back
  /// abandoned cannot land on top of where the user is now.
  int _listing = 0;

  /// Whether a folder listing is in flight, which back may abandon. A save
  /// also sets [_busy] but is never abandoned.
  bool _opening = false;

  @override
  void initState() {
    super.initState();
    final id = widget.reauthAccountId;
    if (id != null) _prefill(id);
  }

  /// Fills in the saved share's address once the records have loaded.
  Future<void> _prefill(String accountId) async {
    try {
      final snapshot = await ref.read(sourceRecordsProvider.future);
      final uri = snapshot.accounts
          .where((a) => a.account.id == accountId)
          .firstOrNull
          ?.servers
          .firstOrNull
          ?.connections
          .firstOrNull
          ?.uri;
      if (mounted && uri != null && _url.text.isEmpty) {
        _url.text = uri.toString();
      }
    } catch (e) {
      debugPrint('[AddWebDav] Could not read the saved share: $e');
    }
  }

  @override
  void dispose() {
    _client.close();
    _url.dispose();
    _user.dispose();
    _password.dispose();
    super.dispose();
  }

  String get _rootDir => _dirOf(_base);

  /// The share's own folder as a backend path: decoded, since the backend
  /// encodes what it is given (`/my%20share` would go out as `my%2520share`).
  static String _dirOf(Uri? base) {
    final path = webDavDecodePath(base?.path ?? '');
    return path.isEmpty ? '/' : path;
  }

  _Problem _problemOf(Object e) =>
      e is BackendUnauthorized ? _Problem.unauthorized : _Problem.unreachable;

  Future<void> _connect() async {
    final parsed = parseServerUrl(_url.text);
    if (parsed == null) {
      setState(() => _problem = _Problem.address);
      return;
    }
    final base = webDavBase(parsed);
    final user = _user.text.trim();
    final password = _password.text;
    if (base.scheme == 'http' &&
        (user.isNotEmpty || password.isNotEmpty) &&
        !isPrivateHost(base.host)) {
      setState(() => _problem = _Problem.httpsRequired);
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    final backend =
        ref.read(webDavConnectorProvider)(base, user, password, _client);
    try {
      await backend.probe();
      final dir = _dirOf(base);
      final folders = await _listFolders(backend, dir);
      if (!mounted) return;
      final id = webDavAccountId(base);
      setState(() {
        _backend = backend;
        _base = base;
        _saved = ref.read(sourcesProvider).any((s) => s.account.id == id);
        _dir = dir;
        _folders = folders;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _pickFoldersKey.currentContext;
        if (target == null) return;
        Scrollable.ensureVisible(target,
            duration: _revealDuration, curve: Curves.easeOutCubic);
      });
    } catch (e) {
      debugPrint('[AddWebDav] Connect failed: $e');
      if (mounted) setState(() => _problem = _problemOf(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<List<FileEntry>> _listFolders(
      FileSystemBackend backend, String dir) async {
    final entries = await backend.list(dir);
    return [
      for (final e in entries)
        if (e.isDir) e,
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
  }

  Future<void> _open(String dir) async {
    final backend = _backend;
    if (backend == null) return;
    final listing = ++_listing;
    setState(() {
      _busy = true;
      _opening = true;
      _problem = null;
    });
    bool current() => mounted && listing == _listing;
    try {
      final folders = await _listFolders(backend, dir);
      if (!current()) return;
      setState(() {
        _dir = trimRootPath(dir);
        _folders = folders;
      });
    } catch (e) {
      debugPrint('[AddWebDav] Listing $dir failed: $e');
      if (current()) setState(() => _problem = _problemOf(e));
    } finally {
      if (current()) {
        setState(() {
          _busy = false;
          _opening = false;
        });
      }
    }
  }

  String _parent(String dir) {
    final trimmed = trimRootPath(dir);
    final i = trimmed.lastIndexOf('/');
    return i <= 0 ? '/' : trimmed.substring(0, i);
  }

  Future<void> _save() async {
    final base = _base;
    if (base == null) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    final accounts = ref.read(filesAccountsProvider);
    // Read before the awaits: the screen may be gone by the time they end.
    final selected = ref.read(selectedSourceIdProvider.notifier);
    try {
      final id = await accounts.addWebDavAccount(
          url: base, user: _user.text.trim(), password: _password.text);
      for (final MapEntry(key: path, value: kind) in _chosen.entries) {
        await accounts.addWebDavRoot(id, path: path, kind: kind);
      }
      selected.select(id);
      if (!mounted) return;
      context.go(sourceHomeLocation(id));
    } catch (e) {
      debugPrint('[AddWebDav] Save failed: $e');
      if (mounted) setState(() => _problem = _Problem.save);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _problemText(AppLocalizations l10n, _Problem p) => switch (p) {
        _Problem.address => l10n.filesWebDavAddressInvalid,
        _Problem.httpsRequired => l10n.filesWebDavHttpsRequired,
        _Problem.unauthorized => l10n.filesWebDavUnauthorized,
        _Problem.unreachable => l10n.filesWebDavUnreachable,
        _Problem.save => l10n.filesWebDavSaveFailed,
      };

  void _toggle(String path, bool on) => setState(() {
        if (on) {
          _chosen.putIfAbsent(path, () => FilesLibraryKind.mixed);
        } else {
          _chosen.remove(path);
        }
      });

  Widget _folderRow(String path, String name, {required bool open}) {
    final key = trimRootPath(path);
    final kind = _chosen[key];
    return ListTile(
      key: ValueKey('webdav-folder-$key'),
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        key: ValueKey('webdav-tick-$key'),
        value: kind != null,
        onChanged: _busy ? null : (on) => _toggle(key, on ?? false),
      ),
      title: Text(name),
      trailing: kind == null
          ? null
          : FilesLibraryKindPicker(
              key: ValueKey('webdav-kind-$key'),
              value: kind,
              onChanged: _busy ? null : (k) => setState(() => _chosen[key] = k),
            ),
      onTap: open && !_busy ? () => _open(path) : null,
    );
  }

  /// Address, user, password and the last problem: the whole screen before
  /// the share answers, and the top of the folder list after.
  List<Widget> _form(AppLocalizations l10n, {required bool connected}) => [
        const FilesExperimentalNotice(key: Key('add-webdav-experimental')),
        const SizedBox(height: 16),
        TextField(
          key: const Key('webdav-url-field'),
          controller: _url,
          autofocus: true,
          enabled: !connected,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(
            labelText: l10n.sourcesServerAddressLabel,
            hintText: 'https://nas.local/dav', // l10n-ignore: example
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('webdav-user-field'),
          controller: _user,
          enabled: !connected,
          decoration: InputDecoration(labelText: l10n.filesWebDavUserLabel),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('webdav-password-field'),
          controller: _password,
          enabled: !connected,
          obscureText: true,
          decoration: InputDecoration(labelText: l10n.filesWebDavPasswordLabel),
          onSubmitted: (_) => connected ? null : _connect(),
        ),
        if (_problem case final p?) ...[
          const SizedBox(height: 16),
          Text(_problemText(l10n, p),
              key: const Key('webdav-error'),
              style: TextStyle(color: Theme.of(context).colorScheme.error)),
        ],
      ];

  Widget _actionButton(AppLocalizations l10n, {required bool connected}) =>
      FilledButton(
        key: Key(connected ? 'webdav-save-button' : 'webdav-connect-button'),
        onPressed: _busy || (connected && _chosen.isEmpty && !_saved)
            ? null
            : (connected ? _save : _connect),
        child: _busy
            ? const SizedBox.square(
                dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(connected ? l10n.commonSave : l10n.loginConnect),
      );

  /// Where the list is and the way up, pinned while the folders scroll
  /// under it. Painted opaque so they do not show through.
  Widget _location(AppLocalizations l10n) => ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  IconButton(
                    key: const Key('webdav-up'),
                    tooltip: l10n.filesWebDavUp,
                    icon: const Icon(Icons.arrow_upward_rounded),
                    onPressed:
                        _busy || _atRoot ? null : () => _open(_parent(_dir)),
                  ),
                  Expanded(
                    child: Text(_dir,
                        key: const Key('webdav-dir'),
                        overflow: TextOverflow.ellipsis),
                  ),
                ],
              ),
              _folderRow(_dir, l10n.filesWebDavThisFolder, open: false),
              const Divider(height: 1),
            ],
          ),
        ),
      );

  Widget _folderBrowser(AppLocalizations l10n) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: CustomScrollView(
              key: const Key('webdav-folder-list'),
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
                  sliver: SliverList.list(children: [
                    ..._form(l10n, connected: true),
                    const SizedBox(height: 24),
                    Text(l10n.filesWebDavPickFolders, key: _pickFoldersKey),
                    const SizedBox(height: 8),
                  ]),
                ),
                PinnedHeaderSliver(child: _location(l10n)),
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                  sliver: _folders.isEmpty
                      ? SliverToBoxAdapter(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(l10n.filesWebDavNoFolders),
                          ),
                        )
                      : SliverList.builder(
                          itemCount: _folders.length,
                          itemBuilder: (_, i) => _folderRow(
                              _folders[i].path, _folders[i].name,
                              open: true),
                        ),
                ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 24),
              child: _actionButton(l10n, connected: true),
            ),
          ),
        ],
      );

  bool get _atRoot => _dir == _rootDir;

  /// Back climbs out of a subfolder before it leaves the setup, so the app
  /// bar arrow and the system gesture never drop a half-picked share. While
  /// a folder is still listing, back abandons it instead: a slow server
  /// never leaves back dead for the length of its timeout.
  void _onPop(bool didPop, Object? _) {
    if (didPop || _backend == null) return;
    if (_opening) {
      setState(() {
        _listing++;
        _busy = false;
        _opening = false;
      });
      return;
    }
    if (!_atRoot && !_busy) _open(_parent(_dir));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    _revealDuration =
        ReducedMotion.duration(context, const Duration(milliseconds: 250));
    final connected = _backend != null;
    return PopScope(
      canPop: !connected || (_atRoot && !_opening),
      onPopInvokedWithResult: _onPop,
      child: Scaffold(
        appBar: AppBar(title: Text(l10n.filesWebDavTitle)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: connected
                ? _folderBrowser(l10n)
                : ListView(
                    padding: const EdgeInsets.all(24),
                    shrinkWrap: true,
                    children: [
                      ..._form(l10n, connected: false),
                      const SizedBox(height: 24),
                      _actionButton(l10n, connected: false),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
