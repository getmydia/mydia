/// Connect an S3-compatible bucket as a files library: provider, bucket and
/// keys, then the folders to add, each with what it holds.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../../../core/sources/connection/source_connection.dart'
    show isPrivateHost;
import '../../../core/sources/files/backend/file_system_backend.dart';
import '../../../core/sources/files/backend/s3_backend.dart';
import '../../../core/sources/files/backend/s3_errors.dart';
import '../../../core/sources/files/files_account.dart';
import '../../../core/sources/files/files_accounts.dart';
import '../../../core/sources/files/media_names.dart';
import '../../../core/sources/files/s3_presets.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/ui/reduced_motion.dart';
import '../../../l10n/l10n.dart';
import '../detail/detail_links.dart';
import '../../widgets/files/experimental_badge.dart';
import '../../widgets/files/remote_folder_picker.dart';
import 'files_library_kind_picker.dart';

/// A problem worded in build, so it follows the language shown.
typedef _Problem = String Function(AppLocalizations l10n);

class AddS3Screen extends ConsumerStatefulWidget {
  const AddS3Screen({super.key, this.reauthAccountId});

  /// A saved bucket to sign in to again: its location is filled in and
  /// locked, and only the keys can change.
  final String? reauthAccountId;

  @override
  ConsumerState<AddS3Screen> createState() => _AddS3ScreenState();
}

class _AddS3ScreenState extends ConsumerState<AddS3Screen> {
  S3Preset _preset = S3Preset.aws;

  /// The style the viewer set with the switch (or the stored one when
  /// signing in again); null follows [_defaultStyle]. Cleared when the
  /// provider changes.
  S3Style? _chosenStyle;
  final _region = TextEditingController(text: S3Preset.aws.defaultRegion);
  final _accountId = TextEditingController();
  final _endpoint = TextEditingController();
  final _bucket = TextEditingController();
  final _prefix = TextEditingController();
  final _accessKey = TextEditingController();
  final _secretKey = TextEditingController();
  _Problem? _problem;
  bool _busy = false;

  /// Signing in again: the stored location, once read. While it loads the
  /// form waits, so the provider list starts on the right choice.
  S3Location? _stored;
  late bool _loading = widget.reauthAccountId != null;

  /// Shared by every backend this screen builds, closed with it.
  final _client = http.Client();

  /// Set once the bucket answered; null while the form is being filled.
  FileSystemBackend? _backend;
  S3Location? _location;
  S3Credentials? _credentials;
  bool _saved = false;
  List<FileEntry> _rootEntries = const [];
  final _chosen = <String, FilesLibraryKind>{};

  /// The folder instructions, scrolled to the top once the bucket answers.
  final _pickFoldersKey = GlobalKey();
  Duration _revealDuration = Duration.zero;

  bool get _locked => _stored != null;

  S3Style get _style => _chosenStyle ?? _defaultStyle;

  /// The preset's style; for a typed endpoint, virtual-hosted on AWS (which
  /// no longer serves path style for new buckets) and path everywhere else.
  S3Style get _defaultStyle {
    if (!_preset.needsEndpoint) return _preset.defaultStyle;
    final host = parseS3Endpoint(_endpoint.text)?.host.toLowerCase() ?? '';
    return host.endsWith('.amazonaws.com') ? S3Style.vhost : S3Style.path;
  }

  @override
  void initState() {
    super.initState();
    for (final c in [
      _region,
      _accountId,
      _endpoint,
      _bucket,
      _accessKey,
      _secretKey,
    ]) {
      c.addListener(_changed);
    }
    final id = widget.reauthAccountId;
    if (id != null) _prefill(id);
  }

  /// Rebuilds so Connect follows whether the form is complete.
  void _changed() {
    if (mounted) setState(() {});
  }

  /// Fills in the saved bucket's location once the records have loaded.
  Future<void> _prefill(String accountId) async {
    S3Location? stored;
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
      stored = uri == null ? null : S3Location.fromConnectionUri(uri);
    } catch (e) {
      debugPrint('[AddS3] Could not read the saved bucket: ${e.runtimeType}');
    }
    if (!mounted) return;
    setState(() {
      _loading = false;
      if (stored == null) return;
      _stored = stored;
      _preset = S3Preset.other;
      _chosenStyle = stored.style;
      _endpoint.text = stored.endpoint.toString();
      _region.text = stored.region;
      _bucket.text = stored.bucket;
      _prefix.text = stored.prefix.endsWith('/')
          ? stored.prefix.substring(0, stored.prefix.length - 1)
          : stored.prefix;
    });
  }

  @override
  void dispose() {
    _client.close();
    for (final c in [
      _region,
      _accountId,
      _endpoint,
      _bucket,
      _prefix,
      _accessKey,
      _secretKey,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  void _choosePreset(S3Preset? preset) {
    if (preset == null || preset == _preset) return;
    setState(() {
      _preset = preset;
      _chosenStyle = null;
      _region.text = preset.defaultRegion ?? '';
      _problem = null;
    });
  }

  bool get _complete {
    bool filled(TextEditingController c) => c.text.trim().isNotEmpty;
    if (!filled(_accessKey) || !filled(_secretKey)) return false;
    if (_locked) return true;
    return filled(_bucket) &&
        (!_preset.needsRegion || filled(_region)) &&
        (!_preset.needsAccountId || filled(_accountId)) &&
        (!_preset.needsEndpoint || filled(_endpoint));
  }

  /// The location the form names, canonical as `addS3Account` stores it
  /// (a prefix typed `/media/` becomes `media/`), or null with [_problem]
  /// set.
  S3Location? _typedLocation() {
    final stored = _stored;
    if (stored != null) return stored;
    final preset = _preset;
    final endpoint = preset.needsEndpoint
        ? parseS3Endpoint(_endpoint.text)
        : preset.endpointFor(region: _region.text, accountId: _accountId.text);
    if (endpoint == null) {
      _problem = (l10n) => l10n.filesS3EndpointInvalid;
      return null;
    }
    if (endpoint.scheme == 'http' && !isPrivateHost(endpoint.host)) {
      _problem = (l10n) => l10n.filesS3ErrorHttpsRequired;
      return null;
    }
    final region =
        preset.needsRegion ? _region.text.trim() : preset.defaultRegion ?? '';
    final typed = S3Location(
      endpoint: endpoint,
      bucket: _bucket.text.trim(),
      prefix: _prefix.text.trim(),
      region: region,
      style: _style,
    );
    final canonical = S3Location.fromConnectionUri(typed.toConnectionUri());
    if (canonical == null) {
      _problem = (l10n) => l10n.filesS3EndpointInvalid;
    }
    return canonical;
  }

  static _Problem _problemOf(Object e, S3Location location) {
    final host = location.displayHost;
    final bucket = location.bucket;
    if (e is! BackendFailure) {
      return (l10n) => l10n.filesS3ErrorUnreachable(host);
    }
    switch (e.code) {
      case kS3CodeClockSkew:
        return (l10n) => l10n.filesS3ErrorClock;
      case kS3CodeWrongRegion:
        final region = e.hint;
        return region == null
            ? (l10n) => l10n.filesS3ErrorRegionUnknown
            : (l10n) => l10n.filesS3ErrorRegion(region);
      case kS3CodeTls:
        // The http:// advice only helps where the form accepts http://.
        return isPrivateHost(location.endpoint.host)
            ? (l10n) => l10n.filesS3ErrorTls(host)
            : (l10n) => l10n.filesS3ErrorTlsPublic(host);
      case kS3CodeBadKeys:
        return (l10n) => l10n.filesS3ErrorBadKeys;
      case kS3CodeCannotList:
        return (l10n) => l10n.filesS3ErrorCannotList;
      case kS3CodeNoSuchBucket:
        return (l10n) => l10n.filesS3ErrorNoBucket(bucket);
    }
    return switch (e) {
      BackendUnreachable(:final status?) => (l10n) =>
          l10n.filesS3ErrorServer('$status'),
      BackendUnreachable() => (l10n) => l10n.filesS3ErrorUnreachable(host),
      BackendUnauthorized() => (l10n) => l10n.filesS3ErrorBadKeys,
      BackendPermissionLost() => (l10n) => l10n.filesS3ErrorCannotList,
      BackendNotFound() => (l10n) => l10n.filesS3ErrorNoBucket(bucket),
    };
  }

  /// Log text for [e]: its type and, for a backend failure, its code. Never
  /// its message, which may name what the viewer typed.
  static String _logText(Object e) => switch (e) {
        BackendFailure(:final code?) => '${e.runtimeType} $code',
        _ => '${e.runtimeType}',
      };

  Future<void> _connect() async {
    final location = _typedLocation();
    if (location == null) {
      setState(() {});
      return;
    }
    final credentials = S3Credentials(
      accessKeyId: _accessKey.text.trim(),
      secretAccessKey: _secretKey.text.trim(),
    );
    setState(() {
      _busy = true;
      _problem = null;
    });
    final backend =
        ref.read(s3ConnectorProvider)(location, credentials, _client);
    try {
      await backend.probe();
      if (_locked) {
        // Signing in again changes only the keys: save once they work.
        _location = location;
        _credentials = credentials;
        await _save();
        return;
      }
      final entries = await backend.list('/');
      if (!mounted) return;
      final id = s3AccountId(location.toConnectionUri());
      setState(() {
        _backend = backend;
        _location = location;
        _credentials = credentials;
        _saved = ref.read(sourcesProvider).any((s) => s.account.id == id);
        _rootEntries = entries;
      });
      WidgetsBinding.instance.addPostFrameCallback((_) {
        final target = _pickFoldersKey.currentContext;
        if (target == null) return;
        Scrollable.ensureVisible(target,
            duration: _revealDuration, curve: Curves.easeOutCubic);
      });
    } catch (e) {
      debugPrint('[AddS3] Connect failed: ${_logText(e)}');
      if (mounted) setState(() => _problem = _problemOf(e, location));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final location = _location;
    final credentials = _credentials;
    if (location == null || credentials == null) return;
    setState(() {
      _busy = true;
      _problem = null;
    });
    final accounts = ref.read(filesAccountsProvider);
    // Read before the awaits: the screen may be gone by the time they end.
    final selected = ref.read(selectedSourceIdProvider.notifier);
    try {
      // Signing in again or changing folders: the bucket the screen was
      // opened for, and only while it is still saved.
      final id = await accounts.addS3Account(
          location: location,
          credentials: credentials,
          signInAgain: widget.reauthAccountId != null);
      for (final MapEntry(key: path, value: kind) in _chosen.entries) {
        await accounts.addS3Root(id, path: path, kind: kind);
      }
      selected.select(id);
      if (!mounted) return;
      context.go(sourceHomeLocation(id));
    } catch (e) {
      debugPrint('[AddS3] Save failed: ${_logText(e)}');
      if (mounted) setState(() => _problem = (l10n) => l10n.filesS3SaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

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
      key: ValueKey('s3-folder-$key'),
      contentPadding: EdgeInsets.zero,
      leading: Checkbox(
        key: ValueKey('s3-tick-$key'),
        value: kind != null,
        onChanged: _busy || busy ? null : (on) => _toggle(key, on ?? false),
      ),
      title: Text(name),
      trailing: kind == null
          ? null
          : FilesLibraryKindPicker(
              key: ValueKey('s3-kind-$key'),
              value: kind,
              onChanged: _busy || busy
                  ? null
                  : (k) => setState(() => _chosen[key] = k),
            ),
      onTap: _busy ? null : onOpen,
    );
  }

  Widget _field(
    String key,
    TextEditingController controller,
    String label, {
    required bool fixed,
    bool obscure = false,
    TextInputType? keyboardType,
    String? hint,
  }) =>
      Padding(
        padding: const EdgeInsets.only(top: 16),
        child: TextField(
          key: Key(key),
          controller: controller,
          readOnly: fixed,
          obscureText: obscure,
          autocorrect: false,
          enableSuggestions: !obscure,
          keyboardType: keyboardType,
          decoration: InputDecoration(labelText: label, hintText: hint),
        ),
      );

  /// Provider, location, keys and the last problem: the whole screen before
  /// the bucket answers, and the top of the folder list after.
  List<Widget> _form(AppLocalizations l10n, {required bool connected}) {
    final fixed = connected || _locked || _busy;
    final keysFixed = connected || _busy;
    final preset = _preset;
    return [
      const FilesExperimentalNotice(key: Key('add-s3-experimental')),
      const SizedBox(height: 16),
      DropdownButtonFormField<S3Preset>(
        key: const Key('s3-provider'),
        initialValue: preset,
        decoration: InputDecoration(labelText: l10n.filesS3Provider),
        items: [
          for (final p in S3Preset.values)
            DropdownMenuItem(value: p, child: Text(p.label(l10n))),
        ],
        onChanged: fixed ? null : _choosePreset,
      ),
      if (preset.needsEndpoint)
        _field('s3-endpoint', _endpoint, l10n.filesS3Endpoint,
            fixed: fixed,
            keyboardType: TextInputType.url,
            hint: 'https://minio.lan:9000'), // l10n-ignore: example address
      if (preset.needsAccountId)
        _field('s3-account-id', _accountId, l10n.filesS3AccountId,
            fixed: fixed),
      if (preset.needsRegion)
        _field('s3-region', _region, l10n.filesS3Region, fixed: fixed),
      _field('s3-bucket', _bucket, l10n.filesS3Bucket, fixed: fixed),
      _field('s3-prefix', _prefix, l10n.filesS3Prefix, fixed: fixed),
      _field('s3-access-key', _accessKey, l10n.filesS3AccessKey,
          fixed: keysFixed),
      _field('s3-secret-key', _secretKey, l10n.filesS3SecretKey,
          fixed: keysFixed, obscure: true),
      const SizedBox(height: 8),
      SwitchListTile(
        key: const Key('s3-style'),
        contentPadding: EdgeInsets.zero,
        title: Text(l10n.filesS3PathStyle),
        value: _style == S3Style.path,
        onChanged: fixed
            ? null
            : (on) => setState(
                () => _chosenStyle = on ? S3Style.path : S3Style.vhost),
      ),
      // Once connected the form scrolls away, so the folder picker's
      // pinned location bar shows it.
      if (_problem case final p? when !connected) ...[
        const SizedBox(height: 16),
        Text(p(l10n),
            key: const Key('s3-error'),
            style: TextStyle(color: Theme.of(context).colorScheme.error)),
      ],
    ];
  }

  Widget _actionButton(AppLocalizations l10n, {required bool connected}) =>
      FilledButton(
        key: Key(connected ? 's3-save' : 's3-connect'),
        onPressed:
            _busy || (connected ? _chosen.isEmpty && !_saved : !_complete)
                ? null
                : (connected ? _save : _connect),
        child: _busy
            ? const SizedBox.square(
                dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            : Text(connected ? l10n.commonSave : l10n.loginConnect),
      );

  Widget _folderBrowser(AppLocalizations l10n, FileSystemBackend backend) =>
      RemoteFolderPicker(
        key: const Key('s3-folder-picker'),
        keyPrefix: 's3',
        backend: backend,
        root: '/',
        initialFolders: _rootEntries,
        busy: _busy,
        problem: _problem?.call(l10n),
        header: [
          ..._form(l10n, connected: true),
          const SizedBox(height: 24),
          Text(l10n.filesWebDavPickFolders, key: _pickFoldersKey),
          const SizedBox(height: 8),
        ],
        footer: _actionButton(l10n, connected: true),
        onPicked: (path) => _toggle(trimRootPath(path), true),
        rowBuilder: (context,
                {required path,
                required title,
                required busy,
                required onOpen}) =>
            _folderRow(path, title, busy: busy, onOpen: onOpen),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    _revealDuration =
        ReducedMotion.duration(context, const Duration(milliseconds: 250));
    final backend = _backend;
    return Scaffold(
      appBar: AppBar(title: Text(l10n.filesS3Title)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: _loading
              ? const CircularProgressIndicator()
              : backend != null
                  ? _folderBrowser(l10n, backend)
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
    );
  }
}
