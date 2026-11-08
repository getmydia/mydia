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
import '../../../l10n/l10n.dart';
import '../detail/detail_links.dart';
import '../../widgets/files/experimental_badge.dart';
import '../../widgets/files/remote_folder_picker.dart';
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
  List<FileEntry> _rootEntries = const [];
  final _chosen = <String, FilesLibraryKind>{};

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
      final entries = await backend.list(dir);
      if (!mounted) return;
      final id = webDavAccountId(base);
      setState(() {
        _backend = backend;
        _base = base;
        _saved = ref.read(sourcesProvider).any((s) => s.account.id == id);
        _rootEntries = entries;
      });
    } catch (e) {
      debugPrint('[AddWebDav] Connect failed: $e');
      if (mounted) setState(() => _problem = _problemOf(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
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

  Widget _folderRow(String path, String name,
      {required bool busy, required VoidCallback? onOpen}) {
    final key = trimRootPath(path);
    final kind = _chosen[key];
    return ListTile(
      key: ValueKey('webdav-folder-$key'),
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        key: ValueKey('webdav-tick-$key'),
        value: kind != null,
        onChanged: _busy || busy ? null : (on) => _toggle(key, on ?? false),
      ),
      title: Text(name),
      trailing: kind == null
          ? null
          : FilesLibraryKindPicker(
              key: ValueKey('webdav-kind-$key'),
              value: kind,
              onChanged: _busy || busy
                  ? null
                  : (k) => setState(() => _chosen[key] = k),
            ),
      onTap: _busy ? null : onOpen,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final connected = _backend != null;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.filesWebDavTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              const FilesExperimentalNotice(
                  key: Key('add-webdav-experimental')),
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
                decoration:
                    InputDecoration(labelText: l10n.filesWebDavUserLabel),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('webdav-password-field'),
                controller: _password,
                enabled: !connected,
                obscureText: true,
                decoration:
                    InputDecoration(labelText: l10n.filesWebDavPasswordLabel),
                onSubmitted: (_) => connected ? null : _connect(),
              ),
              if (_problem case final p?) ...[
                const SizedBox(height: 16),
                Text(_problemText(l10n, p),
                    key: const Key('webdav-error'),
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              if (connected) ...[
                const SizedBox(height: 24),
                Text(l10n.filesWebDavPickFolders),
                const SizedBox(height: 8),
                RemoteFolderPicker(
                  key: const Key('webdav-folder-picker'),
                  backend: _backend!,
                  root: _rootDir,
                  initialFolders: _rootEntries,
                  onPicked: (path) => _toggle(trimRootPath(path), true),
                  rowBuilder: (context,
                          {required path,
                          required title,
                          required busy,
                          required onOpen}) =>
                      _folderRow(path, title, busy: busy, onOpen: onOpen),
                ),
              ],
              const SizedBox(height: 24),
              FilledButton(
                key: Key(
                    connected ? 'webdav-save-button' : 'webdav-connect-button'),
                onPressed: _busy || (connected && _chosen.isEmpty && !_saved)
                    ? null
                    : (connected ? _save : _connect),
                child: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : Text(connected ? l10n.commonSave : l10n.loginConnect),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
