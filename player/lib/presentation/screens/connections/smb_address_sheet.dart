/// Points a saved SMB share at a different server address. The account id,
/// and so its folders, index and watch state, stay the same.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/files/backend/file_system_backend.dart';
import '../../../core/sources/files/files_account.dart';
import '../../../core/sources/files/files_accounts.dart';
import '../../../core/sources/files/smb_addresses.dart' show parseSmbAddress;
import '../../../core/sources/files/smb_discovery.dart';
import '../../../core/sources/files/smb_native.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/sources/store/source_records.dart';
import '../../../l10n/l10n.dart';
import '../../widgets/glass/glass_dialog.dart';
import '../../widgets/glass/glass_sheet.dart';

/// Window width below which the sheet rises from the bottom instead of
/// opening as a dialog.
const double _compactWidth = 600;

/// Opens the Change address sheet for [record], a saved SMB share: a bottom
/// sheet on compact widths, otherwise a dialog around the same content.
Future<void> showSmbAddressSheet(
  BuildContext context, {
  required SourceAccountRecord record,
}) {
  if (MediaQuery.sizeOf(context).width < _compactWidth) {
    return showGlassSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => SmbAddressSheet(record: record),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => GlassDialog(
      content: SizedBox(width: 420, child: SmbAddressSheet(record: record)),
    ),
  );
}

/// What went wrong, worded in `build`.
sealed class _Problem {
  const _Problem();
}

class _Simple extends _Problem {
  const _Simple(this.kind);
  final _Kind kind;
}

class _ShareMissing extends _Problem {
  const _ShareMissing(this.share);
  final String share;
}

enum _Kind { address, unauthorized, accessDenied, unreachable, smb1Only, save }

class SmbAddressSheet extends ConsumerStatefulWidget {
  const SmbAddressSheet({super.key, required this.record});

  final SourceAccountRecord record;

  @override
  ConsumerState<SmbAddressSheet> createState() => _SmbAddressSheetState();
}

class _SmbAddressSheetState extends ConsumerState<SmbAddressSheet> {
  final _host = TextEditingController();
  final _port = TextEditingController();

  StreamSubscription<List<DiscoveredSmbServer>>? _browse;
  List<DiscoveredSmbServer> _servers = const [];

  /// The discovered server the fields were filled from. Cleared once the
  /// viewer edits the host or the port, which makes it a typed address.
  DiscoveredSmbServer? _discovered;

  _Problem? _problem;
  bool _busy = false;

  /// The saved share, which the new address must also serve.
  late final SmbTarget? _current =
      switch (widget.record.servers.firstOrNull?.connections.firstOrNull?.uri) {
    final uri? => smbTargetOf(Uri.parse(normalizeSmbUrl(uri))),
    null => null,
  };

  @override
  void initState() {
    super.initState();
    final current = _current;
    if (current != null) {
      _host.text = current.host;
      if (current.port != kSmbDefaultPort) _port.text = '${current.port}';
    }
    _browse = ref.read(smbDiscoveryProvider).browse().listen((servers) {
      if (mounted) setState(() => _servers = servers);
    });
  }

  @override
  void dispose() {
    unawaited(_browse?.cancel());
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _pick(DiscoveredSmbServer server) => setState(() {
        _host.text = server.host;
        _port.text = server.port == kSmbDefaultPort ? '' : '${server.port}';
        _discovered = server;
        _problem = null;
      });

  /// The stored sign-in, or null when it is missing or unreadable.
  Future<SmbCredentials?> _credentials() async {
    try {
      final json = await ref
          .read(sourceSecretsProvider)
          .accountToken(widget.record.account);
      return json == null ? null : SmbCredentials.fromJson(json);
    } catch (e) {
      debugPrint('[SmbAddress] Could not read the credentials: $e');
      return null;
    }
  }

  static _Problem _problemOf(Object e) => switch (e) {
        BackendUnauthorized() => const _Simple(_Kind.unauthorized),
        BackendPermissionLost() => const _Simple(_Kind.accessDenied),
        BackendUnreachable(message: kSmb1OnlyReason) =>
          const _Simple(_Kind.smb1Only),
        _ => const _Simple(_Kind.unreachable),
      };

  Future<void> _save() async {
    final current = _current;
    final address = parseSmbAddress(_host.text, _port.text);
    if (current == null || address == null) {
      setState(() =>
          _problem = _Simple(current == null ? _Kind.save : _Kind.address));
      return;
    }
    setState(() {
      _busy = true;
      _problem = null;
    });
    // Read before the awaits: the sheet may close while they run.
    final native = ref.read(smbNativeProvider);
    final accounts = ref.read(filesAccountsProvider);
    final navigator = Navigator.of(context);
    final server = _discovered;
    try {
      final credentials = await _credentials();
      if (credentials == null) {
        // Missing or unreadable: sign in again through Edit share.
        if (mounted) {
          setState(() => _problem = const _Simple(_Kind.unauthorized));
        }
        return;
      }
      final shares =
          await native.listShares(address.host, address.port, credentials);
      final share = current.share.toLowerCase();
      if (!shares.any((s) => s.toLowerCase() == share)) {
        if (mounted) setState(() => _problem = _ShareMissing(current.share));
        return;
      }
      if (!await _store(accounts, address, server)) {
        if (mounted) setState(() => _problem = const _Simple(_Kind.save));
        return;
      }
      if (mounted) navigator.pop();
    } catch (e) {
      debugPrint('[SmbAddress] Change failed: $e');
      if (mounted) setState(() => _problem = _problemOf(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Saves the address; false when that failed. A share removed while the
  /// sheet was open counts as done, so the sheet closes quietly.
  Future<bool> _store(FilesAccounts accounts, ({String host, int port}) address,
      DiscoveredSmbServer? server) async {
    try {
      await accounts.setSmbAddress(
        widget.record.account.id,
        host: address.host,
        port: address.port,
        alternatives: server == null
            ? const []
            : [
                if (server.hostname case final hostname?) hostname,
                ...server.alternatives,
              ],
        serviceName: server?.name,
      );
    } on StateError catch (e) {
      debugPrint('[SmbAddress] The share is gone: $e');
    } catch (e) {
      debugPrint('[SmbAddress] Save failed: $e');
      return false;
    }
    return true;
  }

  String _problemText(AppLocalizations l10n, _Problem p) => switch (p) {
        _ShareMissing(:final share) =>
          l10n.filesChangeAddressShareMissing(share),
        _Simple(kind: _Kind.address) => l10n.filesSmbAddressInvalid,
        _Simple(kind: _Kind.unauthorized) => l10n.filesSmbUnauthorized,
        _Simple(kind: _Kind.accessDenied) => l10n.filesSmbAccessDenied,
        _Simple(kind: _Kind.unreachable) => l10n.filesSmbUnreachable,
        _Simple(kind: _Kind.smb1Only) => l10n.filesSmbSmb1Only,
        _Simple(kind: _Kind.save) => l10n.filesSmbSaveFailed,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final theme = Theme.of(context);
    final problem = _problem;
    return SafeArea(
      child: SingleChildScrollView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MediaQuery.viewInsetsOf(context).bottom,
        ),
        child: Column(
          key: const Key('smb-address-sheet'),
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l10n.filesChangeAddress, style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              key: const Key('smb-address-host'),
              controller: _host,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              decoration:
                  InputDecoration(labelText: l10n.filesChangeAddressHost),
              // An edited host is a typed one, whatever filled it.
              onChanged: (_) => _discovered = null,
              onSubmitted: (_) => _busy ? null : _save(),
            ),
            const SizedBox(height: 16),
            TextField(
              key: const Key('smb-address-port'),
              controller: _port,
              enabled: !_busy,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                  labelText: l10n.filesSmbPortLabel, hintText: '445'),
              onChanged: (_) => _discovered = null,
              onSubmitted: (_) => _busy ? null : _save(),
            ),
            if (_servers.isNotEmpty) ...[
              const SizedBox(height: 16),
              Text(l10n.filesSmbServersHeading,
                  style: theme.textTheme.titleSmall),
              for (final s in _servers)
                ListTile(
                  // Discovery keeps the advertised name unique.
                  key: Key('smb-address-server-${s.name}'),
                  contentPadding: EdgeInsets.zero,
                  leading: const Icon(Icons.dns_rounded),
                  title: Text(s.name),
                  subtitle: Text(s.host),
                  selected: identical(s, _discovered),
                  onTap: _busy ? null : () => _pick(s),
                ),
            ],
            if (problem != null)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(_problemText(l10n, problem),
                    key: const Key('smb-address-error'),
                    style: TextStyle(color: theme.colorScheme.error)),
              ),
            const SizedBox(height: 24),
            FilledButton(
              key: const Key('smb-address-save'),
              onPressed: _busy ? null : _save,
              child: _busy
                  ? const SizedBox.square(
                      dimension: 18,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(l10n.filesChangeAddressSave),
            ),
          ],
        ),
      ),
    );
  }
}
