library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../core/sources/connection/source_connection.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/source_factories.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/sources/stash/stash_client.dart';
import '../../../core/sources/store/source_records.dart';
import '../../../core/sources/store/source_secrets.dart';
import '../../../domain/sources/source_error.dart';

/// What the viewer typed, as a server root, or null when it cannot be one.
/// A bare `host:port` is taken as HTTP, which is how Stash ships.
Uri? parseStashUrl(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final withScheme = trimmed.contains('://') ? trimmed : 'http://$trimmed';
  final uri = Uri.tryParse(withScheme);
  if (uri == null || uri.host.isEmpty) return null;
  if (uri.scheme != 'http' && uri.scheme != 'https') return null;
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );
}

Future<SourceAccountRecord> saveStashSource(
  WidgetRef ref, {
  required Uri uri,
  required String apiKey,
  String? reauthAccountId,
}) async {
  final snapshot = await ref.read(sourceRecordsProvider.future);
  final existing = reauthAccountId == null
      ? null
      : snapshot.accounts
          .where((a) => a.account.id == reauthAccountId)
          .firstOrNull;
  final accountId =
      existing?.account.id ?? const Uuid().v4().replaceAll('-', '');
  final account = existing?.account.copyWith(needsReauth: false) ??
      ProviderAccount(
        id: accountId,
        kind: SourceKind.stash,
        displayName: uri.host,
        storageNamespace: SourceSecrets.newStorageNamespace(accountId),
        activeProfileId: 'owner',
      );
  final secrets = ref.read(sourceSecretsProvider);
  if (apiKey.isNotEmpty) await secrets.writeAccountToken(account, apiKey);
  final record = SourceAccountRecord(
    account: account,
    profiles: [
      SourceProfile(
          id: 'owner', accountId: accountId, name: 'Owner', isOwner: true),
    ],
    servers: [
      SourceServer(
        id: 'main',
        accountId: accountId,
        profileId: 'owner',
        name: uri.host,
        connections: [
          ServerConnection(uri: uri, local: isPrivateHost(uri.host)),
        ],
      ),
    ],
    addedAtMs: existing?.addedAtMs ?? DateTime.now().millisecondsSinceEpoch,
  );
  await ref.read(sourceRecordsProvider.notifier).putAccount(record);
  for (final source in record.sources) {
    ref.invalidate(mediaSourceProvider(source.id));
  }
  ref.read(selectedSourceIdProvider.notifier).select(record.sources.first.id);
  return record;
}

class StashConnectScreen extends ConsumerStatefulWidget {
  const StashConnectScreen({super.key, this.reauthAccountId});

  final String? reauthAccountId;

  @override
  ConsumerState<StashConnectScreen> createState() => _StashConnectScreenState();
}

class _StashConnectScreenState extends ConsumerState<StashConnectScreen> {
  final _url = TextEditingController();
  final _key = TextEditingController();
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final id = widget.reauthAccountId;
    if (id != null) {
      final source = ref
          .read(thirdPartySourcesProvider)
          .where((s) => s.account.id == id)
          .firstOrNull;
      final uri = source?.server.connections.firstOrNull?.uri;
      if (uri != null) _url.text = uri.toString();
    }
  }

  @override
  void dispose() {
    _url.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final uri = parseStashUrl(_url.text);
    if (uri == null) {
      setState(() => _error =
          'Enter the address of your Stash server, like http://192.168.1.20:9999');
      return;
    }
    final key = _key.text.trim();
    setState(() {
      _busy = true;
      _error = null;
    });
    final connection = SingleConnection(
      connection: ServerConnection(uri: uri),
      probe: (_) async => true,
    );
    try {
      await StashClient(
        connection: connection,
        http: ref.read(sourceHttpProvider),
        apiKey: () async => key.isEmpty ? null : key,
      ).checkStatus();
      final record = await saveStashSource(ref,
          uri: uri, apiKey: key, reauthAccountId: widget.reauthAccountId);
      if (!mounted) return;
      context.go('/s/${record.sources.first.id.value}');
    } on SourceException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.kind == SourceErrorKind.unauthorized
          ? 'Stash rejected that API key. Copy it from Stash under '
              'Settings, Security.'
          : e.viewerMessage);
    } finally {
      connection.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connect Stash')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: ListView(
            padding: const EdgeInsets.all(24),
            shrinkWrap: true,
            children: [
              TextField(
                key: const Key('stash-url-field'),
                controller: _url,
                autofocus: true,
                keyboardType: TextInputType.url,
                decoration: const InputDecoration(
                  labelText: 'Server address',
                  hintText: 'http://192.168.1.20:9999',
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                key: const Key('stash-key-field'),
                controller: _key,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'API key (if Stash asks for a login)',
                ),
                onSubmitted: (_) => _connect(),
              ),
              if (_error case final error?) ...[
                const SizedBox(height: 16),
                Text(error,
                    style:
                        TextStyle(color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 24),
              FilledButton(
                key: const Key('stash-connect-button'),
                onPressed: _busy ? null : _connect,
                child: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Connect'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
