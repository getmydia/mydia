/// Connect an SMB share as a files library: pick a server (found on the
/// network or typed), sign in, pick a share, then the folders to add, each
/// with what it holds. Also signs a saved share in again.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/sources/files/backend/file_system_backend.dart';
import '../../../core/sources/files/backend/smb_backend.dart';
import '../../../core/sources/files/files_account.dart';
import '../../../core/sources/files/files_accounts.dart';
import '../../../core/sources/files/media_names.dart';
import '../../../core/sources/files/smb_discovery.dart';
import '../../../core/sources/files/smb_native.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../l10n/l10n.dart';
import '../detail/detail_links.dart';
import '../../widgets/files/experimental_badge.dart';
import '../../widgets/files/remote_folder_picker.dart';
import 'files_library_kind_picker.dart';

enum _Step { servers, login, shares, folders }

enum _Problem {
  address,
  unauthorized,
  notFound,
  accessDenied,
  unreachable,
  smb1Only,
  noShares,
  save,
}

class AddSmbScreen extends ConsumerStatefulWidget {
  const AddSmbScreen({
    super.key,
    this.reauthAccountId,
    this.platform,
    this.discoveryTimeout = const Duration(seconds: 5),
  });

  /// A saved share to sign in to again: its server and share are filled in.
  final String? reauthAccountId;

  /// [defaultTargetPlatform] when null. Overridable for tests.
  final TargetPlatform? platform;

  /// How long a search may find nothing before the empty state shows.
  final Duration discoveryTimeout;

  @override
  ConsumerState<AddSmbScreen> createState() => _AddSmbScreenState();
}

class _AddSmbScreenState extends ConsumerState<AddSmbScreen> {
  final _host = TextEditingController();
  final _port = TextEditingController();
  final _user = TextEditingController();
  final _password = TextEditingController();
  final _domain = TextEditingController();

  _Step _step = _Step.servers;
  _Problem? _problem;
  bool _busy = false;

  /// True when the server came from discovery or the saved share, so its
  /// address is not editable.
  bool _addressFixed = false;

  /// The discovered server, when that is how it was picked. Its addresses
  /// are tried best first; the first that answers is the one saved, and the
  /// hostname and the rest are kept as alternatives. The host field is
  /// read-only for a picked server, so the saved host is always one of its
  /// own.
  DiscoveredSmbServer? _discovered;

  /// Re-login mode only: whether the saved share needs signing in again.
  /// When it does not, the viewer came to add folders, so a sign-in goes on
  /// to the folder picker instead of closing the screen.
  bool _signInAgain = true;

  // Discovery.
  StreamSubscription<List<DiscoveredSmbServer>>? _browse;
  Timer? _quietTimer;
  List<DiscoveredSmbServer> _servers = const [];
  bool _browseEmpty = false;
  bool _quiet = false;

  // Read in initState: `ref` is not safe to use from dispose.
  late final SmbNative _native = ref.read(smbNativeProvider);

  // Set by the login.
  String _hostName = '';
  int _portNumber = kSmbDefaultPort;
  SmbCredentials? _credentials;
  List<String> _shares = const [];

  // Set once a share is picked.
  String? _share;

  /// False in re-login mode until the saved share has been read; Connect
  /// stays off until then, and for good when there is no saved share.
  late bool _prefilled = widget.reauthAccountId == null;
  SmbBackend? _backend;
  bool _saved = false;
  final _chosen = <String, FilesLibraryKind>{};

  bool get _reauth => widget.reauthAccountId != null;

  @override
  void initState() {
    super.initState();
    final id = widget.reauthAccountId;
    if (id != null) {
      _step = _Step.login;
      _prefill(id);
    } else {
      _startBrowsing();
    }
  }

  void _startBrowsing() {
    _quietTimer = Timer(widget.discoveryTimeout, () {
      if (mounted) setState(() => _quiet = true);
    });
    _browse = ref.read(smbDiscoveryProvider).browse().listen((servers) {
      if (!mounted) return;
      setState(() {
        _servers = servers;
        _browseEmpty = servers.isEmpty;
      });
    });
  }

  void _stopBrowsing() {
    _quietTimer?.cancel();
    _quietTimer = null;
    unawaited(_browse?.cancel());
    _browse = null;
  }

  /// Fills in the saved share's server once the records have loaded.
  Future<void> _prefill(String accountId) async {
    try {
      final snapshot = await ref.read(sourceRecordsProvider.future);
      final record =
          snapshot.accounts.where((a) => a.account.id == accountId).firstOrNull;
      final uri = record?.servers.firstOrNull?.connections.firstOrNull?.uri;
      if (!mounted) return;
      _signInAgain = record?.account.needsReauth ?? true;
      if (uri == null) {
        setState(() => _problem = _Problem.save);
        return;
      }
      final target = smbTargetOf(Uri.parse(normalizeSmbUrl(uri)));
      setState(() {
        _host.text = target.host;
        if (target.port != kSmbDefaultPort) _port.text = '${target.port}';
        _share = target.share;
        _addressFixed = true;
        _prefilled = true;
      });
    } catch (e) {
      debugPrint('[AddSmb] Could not read the saved share: $e');
      if (mounted) setState(() => _problem = _Problem.save);
    }
  }

  /// A picker backend that was never saved leaves loopback tokens behind.
  /// A saved account's belong to its source and are left alone.
  void _closeUnsavedBackend() {
    final backend = _backend;
    if (backend == null || _saved) return;
    unawaited(_native.closeAccount(backend.accountId).catchError((Object e) {
      debugPrint('[AddSmb] Could not close the account: $e');
    }));
  }

  @override
  void dispose() {
    _stopBrowsing();
    _closeUnsavedBackend();
    _host.dispose();
    _port.dispose();
    _user.dispose();
    _password.dispose();
    _domain.dispose();
    super.dispose();
  }

  /// `smb://host[:port]/share`, with an IPv6 host bracketed by [Uri].
  static Uri _urlOf(String host, int port, String share) => Uri(
        scheme: 'smb',
        host: host,
        port: port == kSmbDefaultPort ? null : port,
        path: '/$share',
      );

  void _pickServer(DiscoveredSmbServer server) {
    _stopBrowsing();
    setState(() {
      _host.text = server.host;
      _port.text = server.port == kSmbDefaultPort ? '' : '${server.port}';
      _addressFixed = true;
      _discovered = server;
      _problem = null;
      _step = _Step.login;
    });
  }

  void _pickManual() {
    _stopBrowsing();
    setState(() {
      _addressFixed = false;
      _discovered = null;
      _problem = null;
      _step = _Step.login;
    });
  }

  _Problem _problemOf(Object e) => switch (e) {
        BackendUnauthorized() => _Problem.unauthorized,
        BackendNotFound() => _Problem.notFound,
        BackendPermissionLost() => _Problem.accessDenied,
        BackendUnreachable(message: kSmb1OnlyReason) => _Problem.smb1Only,
        _ => _Problem.unreachable,
      };

  static bool _validPort(int? port) =>
      port != null && port >= 1 && port <= 65535;

  /// The typed host and port, or null when they cannot be used. An IPv6
  /// literal loses its brackets. Text with exactly one colon and no brackets
  /// is `host:port` (`nas.local:4455`); more colons are an IPv6 literal. A
  /// port given that way wins over the port field.
  ({String host, int port})? _typedAddress() {
    var host = _host.text.trim();
    int? inlinePort;
    if (host.startsWith('[') && host.endsWith(']')) {
      host = host.substring(1, host.length - 1);
    } else if (':'.allMatches(host).length == 1) {
      final colon = host.indexOf(':');
      inlinePort = int.tryParse(host.substring(colon + 1));
      if (!_validPort(inlinePort)) return null;
      host = host.substring(0, colon);
    }
    if (host.isEmpty || host.contains(RegExp(r'[\s/]'))) return null;
    final text = _port.text.trim();
    final fieldPort = text.isEmpty ? kSmbDefaultPort : int.tryParse(text);
    final port = inlinePort ?? fieldPort;
    if (!_validPort(port)) return null;
    return (host: host, port: port!);
  }

  Future<void> _connect({required bool guest}) async {
    final address = _typedAddress();
    if (address == null) {
      setState(() => _problem = _Problem.address);
      return;
    }
    final host = address.host;
    final port = address.port;
    final domain = _domain.text.trim();
    final credentials = guest
        ? const SmbCredentials(user: '', password: '', domain: null)
        : SmbCredentials(
            user: _user.text.trim(),
            password: _password.text,
            domain: domain.isEmpty ? null : domain,
          );
    setState(() {
      _busy = true;
      _problem = null;
    });
    // Read before the awaits: the screen may be gone by the time they end,
    // and a sign-in that succeeded is still saved.
    final accounts = ref.read(filesAccountsProvider);
    try {
      final share = _share;
      if (_reauth) {
        if (share == null) {
          setState(() => _problem = _Problem.save);
          return;
        }
        await _native.probe(
            SmbTarget(host: host, port: port, share: share), credentials, '/');
        if (_signInAgain) {
          await _saveCredentials(accounts, host, port, share, credentials);
          return;
        }
        // Add folders: the credentials are saved with them.
        if (!mounted) return;
        setState(() {
          _hostName = host;
          _portNumber = port;
          _credentials = credentials;
        });
        _pickShare(share);
        return;
      }
      final (shares, reached) =
          await _listSharesAt(_candidates(host), port, credentials);
      if (!mounted) return;
      if (shares.isEmpty) {
        setState(() => _problem = _Problem.noShares);
        return;
      }
      setState(() {
        _hostName = reached;
        _portNumber = port;
        _credentials = credentials;
        _shares = shares;
        _step = _Step.shares;
      });
    } catch (e) {
      debugPrint('[AddSmb] Connect failed: $e');
      if (mounted) setState(() => _problem = _problemOf(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The addresses to try for [host]: every one the discovered server
  /// advertised when [host] is its first, else [host] alone.
  List<String> _candidates(String host) {
    final addresses = _discovered?.addresses ?? const <String>[];
    return addresses.firstOrNull == host ? addresses : [host];
  }

  /// Further hosts to save with the one that answered: the discovered
  /// server's hostname, then its other addresses. None for a typed host.
  List<String> get _alternatives {
    final server = _discovered;
    if (server == null) return const [];
    final hostname = server.hostname;
    return [
      if (hostname != null) hostname,
      ...server.addresses.where((a) => a != _hostName),
    ];
  }

  /// Lists the shares at the first of [hosts] that can be reached, and
  /// returns them with that host. Only an unreachable address moves on: a
  /// refused login or an SMB1-only server would answer the same anywhere.
  Future<(List<String>, String)> _listSharesAt(
      List<String> hosts, int port, SmbCredentials credentials) async {
    for (var i = 0;; i++) {
      final host = hosts[i];
      try {
        return (await _native.listShares(host, port, credentials), host);
      } on BackendUnreachable catch (e) {
        if (i == hosts.length - 1 || e.message == kSmb1OnlyReason) rethrow;
        debugPrint('[AddSmb] $host unreachable, trying the next address: $e');
      }
    }
  }

  /// Re-login: the same URL is the same account, so only the credentials
  /// change and `needsReauth` clears. A share removed while the probe ran
  /// stays removed.
  Future<void> _saveCredentials(FilesAccounts accounts, String host, int port,
      String share, SmbCredentials credentials) async {
    try {
      await accounts.addSmbAccount(
          url: _urlOf(host, port, share),
          credentials: credentials,
          signInAgain: true,
          alternatives: _alternatives,
          serviceName: _discovered?.name);
    } catch (e) {
      debugPrint('[AddSmb] Save failed: $e');
      if (mounted) setState(() => _problem = _Problem.save);
      return;
    }
    if (mounted) context.pop();
  }

  void _pickShare(String share) {
    final url = _urlOf(_hostName, _portNumber, share);
    final credentials = _credentials;
    if (credentials == null) return;
    setState(() {
      _share = share;
      _chosen.clear();
      _backend = SmbBackend(
        native: _native,
        accountId: smbAccountId(url),
        target: smbTargetOf(Uri.parse(normalizeSmbUrl(url))),
        credentials: credentials,
      );
      _saved = ref
          .read(sourcesProvider)
          .any((s) => s.account.id == _backend?.accountId);
      _step = _Step.folders;
    });
  }

  /// Back at a share's root: the share list again, with the sign-in kept,
  /// so a wrong share (or one whose root would not list) costs one step.
  void _backToShares() {
    _closeUnsavedBackend();
    setState(() {
      _backend = null;
      _share = null;
      _saved = false;
      _chosen.clear();
      _problem = null;
      _step = _Step.shares;
    });
  }

  Future<void> _save() async {
    final share = _share;
    final credentials = _credentials;
    if (share == null || credentials == null) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    final accounts = ref.read(filesAccountsProvider);
    final selected = ref.read(selectedSourceIdProvider.notifier);
    try {
      final discovered = _discovered?.name;
      final id = await accounts.addSmbAccount(
        url: _urlOf(_hostName, _portNumber, share),
        credentials: credentials,
        displayName: discovered == null ? null : '$discovered / $share',
        alternatives: _alternatives,
        serviceName: discovered,
      );
      // Saved: its playback tokens now belong to the source, not this screen.
      _saved = true;
      for (final MapEntry(key: path, value: kind) in _chosen.entries) {
        await accounts.addSmbRoot(id, path: path, kind: kind);
      }
      selected.select(id);
      if (!mounted) return;
      context.go(sourceHomeLocation(id));
    } catch (e) {
      debugPrint('[AddSmb] Save failed: $e');
      if (mounted) setState(() => _problem = _Problem.save);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _problemText(AppLocalizations l10n, _Problem p) => switch (p) {
        _Problem.address => l10n.filesSmbAddressInvalid,
        _Problem.unauthorized => l10n.filesSmbUnauthorized,
        _Problem.notFound => l10n.filesSmbNotFound,
        _Problem.accessDenied => l10n.filesSmbAccessDenied,
        _Problem.unreachable => l10n.filesSmbUnreachable,
        _Problem.smb1Only => l10n.filesSmbSmb1Only,
        _Problem.noShares => l10n.filesSmbNoShares,
        _Problem.save => l10n.filesSmbSaveFailed,
      };

  void _toggle(String path, bool on) => setState(() {
        if (on) {
          _chosen.putIfAbsent(path, () => FilesLibraryKind.mixed);
        } else {
          _chosen.remove(path);
        }
      });

  Widget _error(BuildContext context, AppLocalizations l10n) {
    final p = _problem;
    if (p == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Text(_problemText(l10n, p),
          key: const Key('smb-error'),
          style: TextStyle(color: Theme.of(context).colorScheme.error)),
    );
  }

  // -- Steps ---------------------------------------------------------------

  Widget _serversStep(BuildContext context, AppLocalizations l10n) {
    final isIos =
        (widget.platform ?? defaultTargetPlatform) == TargetPlatform.iOS;
    final none = _servers.isEmpty && (_browseEmpty || _quiet);
    return Column(
      key: const Key('smb-servers'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.filesSmbServersHeading,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        if (_servers.isEmpty && !none)
          Text(l10n.filesSmbSearching, key: const Key('smb-searching')),
        for (final s in _servers)
          ListTile(
            // Keyed by the advertised name, which discovery keeps unique:
            // two rows can share a host (two ports) or a first address.
            key: Key('smb-server-${s.name}'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.dns_rounded),
            title: Text(s.name),
            subtitle: Text(s.host),
            onTap: () => _pickServer(s),
          ),
        if (none) ...[
          Text(l10n.filesSmbNoneFound, key: const Key('smb-none-found')),
          if (isIos)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(l10n.filesSmbLocalNetworkDenied,
                  key: const Key('smb-local-network-denied')),
            ),
        ],
        const Divider(),
        ListTile(
          key: const Key('smb-manual'),
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.edit_rounded),
          title: Text(l10n.filesSmbManualEntry),
          subtitle: Text(l10n.filesSmbManualHint),
          onTap: _pickManual,
        ),
      ],
    );
  }

  Widget _loginStep(BuildContext context, AppLocalizations l10n) {
    return Column(
      key: const Key('smb-login'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextField(
          key: const Key('smb-host-field'),
          controller: _host,
          readOnly: _addressFixed,
          autofocus: !_addressFixed,
          keyboardType: TextInputType.url,
          decoration: InputDecoration(labelText: l10n.filesSmbHostLabel),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('smb-port-field'),
          controller: _port,
          readOnly: _addressFixed,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(
              labelText: l10n.filesSmbPortLabel, hintText: '445'),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('smb-user-field'),
          controller: _user,
          autofocus: _addressFixed,
          decoration: InputDecoration(labelText: l10n.filesSmbUserLabel),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('smb-password-field'),
          controller: _password,
          obscureText: true,
          decoration: InputDecoration(labelText: l10n.filesSmbPasswordLabel),
          onSubmitted: (_) =>
              _busy || !_prefilled ? null : _connect(guest: false),
        ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('smb-domain-field'),
          controller: _domain,
          decoration: InputDecoration(labelText: l10n.filesSmbDomainLabel),
        ),
        _error(context, l10n),
        const SizedBox(height: 24),
        FilledButton(
          key: const Key('smb-connect-button'),
          onPressed: _busy || !_prefilled ? null : () => _connect(guest: false),
          child: _busy
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : Text(l10n.loginConnect),
        ),
        const SizedBox(height: 8),
        TextButton(
          key: const Key('smb-guest'),
          onPressed: _busy || !_prefilled ? null : () => _connect(guest: true),
          child: Text(l10n.filesSmbGuest),
        ),
      ],
    );
  }

  Widget _sharesStep(BuildContext context, AppLocalizations l10n) {
    return Column(
      key: const Key('smb-shares'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.filesSmbPickShare),
        const SizedBox(height: 8),
        for (final share in _shares)
          ListTile(
            key: Key('smb-share-$share'),
            contentPadding: EdgeInsets.zero,
            leading: const Icon(Icons.folder_shared_rounded),
            title: Text(share),
            onTap: () => _pickShare(share),
          ),
      ],
    );
  }

  Widget _folderRow(String path, String name,
      {required bool busy, required VoidCallback? onOpen}) {
    final key = trimRootPath(path);
    final kind = _chosen[key];
    return ListTile(
      key: ValueKey('smb-folder-$key'),
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        key: ValueKey('smb-tick-$key'),
        value: kind != null,
        onChanged: _busy || busy ? null : (on) => _toggle(key, on ?? false),
      ),
      title: Text(name),
      trailing: kind == null
          ? null
          : FilesLibraryKindPicker(
              key: ValueKey('smb-kind-$key'),
              value: kind,
              onChanged: _busy || busy
                  ? null
                  : (k) => setState(() => _chosen[key] = k),
            ),
      onTap: _busy ? null : onOpen,
    );
  }

  /// The whole screen once a share is open: the folders scroll under the
  /// picker's pinned location bar (which also shows a failed save), with
  /// save kept below them. The picker owns back: it climbs out of a
  /// subfolder, abandons a slow listing, and holds during a save; at the
  /// share's root it returns to the share list, when there is one.
  Widget _foldersStep(
      BuildContext context, AppLocalizations l10n, FileSystemBackend backend) {
    return RemoteFolderPicker(
      key: const Key('smb-folders'),
      keyPrefix: 'smb',
      backend: backend,
      root: '/',
      busy: _busy,
      onExit: _shares.isEmpty ? null : _backToShares,
      problem: switch (_problem) {
        final p? => _problemText(l10n, p),
        null => null,
      },
      header: [
        const FilesExperimentalNotice(key: Key('add-smb-experimental')),
        const SizedBox(height: 16),
        Text(l10n.filesWebDavPickFolders),
        const SizedBox(height: 8),
      ],
      footer: FilledButton(
        key: const Key('smb-save-button'),
        onPressed: _busy || (_chosen.isEmpty && !_saved) ? null : _save,
        child: _busy
            ? const SizedBox.square(
                dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(l10n.commonSave),
      ),
      onPicked: (path) => _toggle(trimRootPath(path), true),
      rowBuilder: (context,
              {required path,
              required title,
              required busy,
              required onOpen}) =>
          _folderRow(path, title, busy: busy, onOpen: onOpen),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final backend = _backend;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.filesSmbTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: _step == _Step.folders && backend != null
              ? _foldersStep(context, l10n, backend)
              : ListView(
                  padding: const EdgeInsets.all(24),
                  shrinkWrap: true,
                  children: [
                    const FilesExperimentalNotice(
                        key: Key('add-smb-experimental')),
                    const SizedBox(height: 16),
                    switch (_step) {
                      _Step.servers => _serversStep(context, l10n),
                      _Step.login => _loginStep(context, l10n),
                      _Step.shares => _sharesStep(context, l10n),
                      _Step.folders => const SizedBox.shrink(),
                    },
                  ],
                ),
        ),
      ),
    );
  }
}
