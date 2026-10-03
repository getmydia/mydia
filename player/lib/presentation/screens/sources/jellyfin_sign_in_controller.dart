/// Signing in to a Jellyfin server: check the address, then Quick Connect
/// (approve a code from a client already signed in) or username and
/// password, then store the account.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/sources/connection/source_connection.dart';
import '../../../core/sources/jellyfin/jellyfin_auth.dart';
import '../../../core/sources/jellyfin/jellyfin_client.dart';
import '../../../core/sources/jellyfin/jellyfin_connections.dart';
import '../../../core/sources/jellyfin/jellyfin_identity.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/source_factories.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/sources/store/source_records.dart';
import '../../../core/sources/store/source_secrets.dart';
import '../../../domain/sources/source_error.dart';
import 'server_url.dart';

final jellyfinQuickConnectPollProvider = Provider<Duration>(
  (ref) => const Duration(seconds: 3),
);

sealed class JellyfinSignInState {
  const JellyfinSignInState();
}

final class JellyfinEnterAddress extends JellyfinSignInState {
  const JellyfinEnterAddress({this.error});
  final String? error;
}

final class JellyfinChecking extends JellyfinSignInState {
  const JellyfinChecking();
}

final class JellyfinQuickConnect extends JellyfinSignInState {
  const JellyfinQuickConnect({required this.code, this.expired = false});
  final String code;
  final bool expired;
}

final class JellyfinPassword extends JellyfinSignInState {
  const JellyfinPassword({this.error, required this.quickConnectAvailable});
  final String? error;
  final bool quickConnectAvailable;
}

final class JellyfinSignedIn extends JellyfinSignInState {
  const JellyfinSignedIn(this.source);
  final SourceId source;
}

class JellyfinSignInController extends Notifier<JellyfinSignInState> {
  JellyfinSignInController(this.reauthAccountId);

  /// Set when signing in again: the account keeps its id, namespace and add
  /// date; its token is replaced.
  final String? reauthAccountId;

  Timer? _poll;
  bool _checking = false;
  Uri? _base;
  JellyfinServerInfo? _info;
  JellyfinAuth? _auth;
  bool _quickConnect = false;

  @override
  JellyfinSignInState build() {
    ref.onDispose(() => _poll?.cancel());
    return const JellyfinEnterAddress();
  }

  Future<void> submitAddress(String text) async {
    _poll?.cancel();
    final uri = parseServerUrl(text);
    if (uri == null) {
      state = const JellyfinEnterAddress(
        error: 'Enter the address of your Jellyfin server, like '
            'http://192.168.1.30:8096',
      );
      return;
    }
    if (uri.scheme == 'http' && !isPrivateHost(uri.host)) {
      state = const JellyfinEnterAddress(
        error: 'Use https:// for a Jellyfin server outside your network, '
            'so your password is not sent in the clear.',
      );
      return;
    }
    state = const JellyfinChecking();
    try {
      final http = ref.read(sourceHttpProvider);
      final info = await jellyfinPublicInfo(http, uri);
      if (!ref.mounted) return;
      if (!info.isJellyfin) {
        state = const JellyfinEnterAddress(
          error: 'This is not a Jellyfin server.',
        );
        return;
      }
      if (!info.supported) {
        state = const JellyfinEnterAddress(
          error: 'Jellyfin 10.9 or newer is required.',
        );
        return;
      }
      if (!isValidSourceIdComponent(info.id)) {
        state = const JellyfinEnterAddress(
          error: 'This Jellyfin server sent an id this app cannot use.',
        );
        return;
      }
      final auth = JellyfinAuth(
        http: http,
        base: uri,
        identity: await ref.read(jellyfinIdentityProvider.future),
      );
      _base = uri;
      _info = info;
      _auth = auth;
      _quickConnect = await auth.quickConnectEnabled();
      if (!ref.mounted) return;
      if (_quickConnect) {
        await startQuickConnect();
      } else {
        state = const JellyfinPassword(quickConnectAvailable: false);
      }
    } on SourceException catch (e) {
      if (ref.mounted) state = JellyfinEnterAddress(error: e.viewerMessage);
    } catch (_) {
      if (ref.mounted) {
        state = const JellyfinEnterAddress(
          error: 'Could not reach this Jellyfin server. Try again.',
        );
      }
    }
  }

  Future<void> startQuickConnect() async {
    final auth = _auth;
    if (auth == null) return;
    _poll?.cancel();
    state = const JellyfinChecking();
    try {
      final code = await auth.initiateQuickConnect();
      if (!ref.mounted) return;
      state = JellyfinQuickConnect(code: code.code);
      _poll = Timer.periodic(
        ref.read(jellyfinQuickConnectPollProvider),
        (_) => unawaited(_check(auth, code)),
      );
    } on SourceException catch (e) {
      if (ref.mounted) {
        state = JellyfinPassword(
          error: e.viewerMessage,
          quickConnectAvailable: _quickConnect,
        );
      }
    } catch (_) {
      if (ref.mounted) state = _signInFailed();
    }
  }

  JellyfinPassword _signInFailed() => JellyfinPassword(
        error: 'Could not sign in to Jellyfin. Try again.',
        quickConnectAvailable: _quickConnect,
      );

  Future<void> _check(JellyfinAuth auth, QuickConnectCode code) async {
    if (_checking || !ref.mounted) return;
    _checking = true;
    try {
      if (!await auth.quickConnectApproved(code.secret) || !ref.mounted) {
        return;
      }
      _poll?.cancel();
      state = const JellyfinChecking();
      await _save(await auth.withQuickConnect(code.secret));
    } on SourceException catch (e) {
      _poll?.cancel();
      if (!ref.mounted) return;
      state = e.kind == SourceErrorKind.notFound
          ? JellyfinQuickConnect(code: code.code, expired: true)
          : JellyfinPassword(
              error: e.viewerMessage,
              quickConnectAvailable: _quickConnect,
            );
    } catch (_) {
      _poll?.cancel();
      if (ref.mounted) state = _signInFailed();
    } finally {
      _checking = false;
    }
  }

  void usePassword() {
    _poll?.cancel();
    state = JellyfinPassword(quickConnectAvailable: _quickConnect);
  }

  Future<void> submitPassword(String username, String password) async {
    final auth = _auth;
    if (auth == null) return;
    state = const JellyfinChecking();
    try {
      await _save(await auth.withPassword(username.trim(), password));
    } on SourceException catch (e) {
      if (!ref.mounted) return;
      state = JellyfinPassword(
        error: e.kind == SourceErrorKind.unauthorized
            ? 'Wrong username or password.'
            : e.viewerMessage,
        quickConnectAvailable: _quickConnect,
      );
    } catch (_) {
      if (ref.mounted) state = _signInFailed();
    }
  }

  Future<void> _save(JellyfinSession session) async {
    final base = _base!;
    final info = _info!;
    if (!isValidSourceIdComponent(session.userId)) {
      throw const SourceException.server(
        'Jellyfin sent a user id this app cannot use.',
      );
    }
    try {
      final snapshot = await ref.read(sourceRecordsProvider.future);
      final existing = reauthAccountId == null
          ? null
          : snapshot.accounts
              .where((a) => a.account.id == reauthAccountId)
              .firstOrNull;
      final accountId =
          existing?.account.id ?? const Uuid().v4().replaceAll('-', '');
      // A re-auth may sign in as a different user, so the active profile
      // follows the session rather than the old record.
      final account = ProviderAccount(
        id: accountId,
        kind: SourceKind.jellyfin,
        displayName: session.userName,
        storageNamespace: existing?.account.storageNamespace ??
            SourceSecrets.newStorageNamespace(accountId),
        activeProfileId: session.userId,
      );
      // Token first: a stored server without it would fail every request.
      await ref
          .read(sourceSecretsProvider)
          .writeAccountToken(account, session.accessToken);
      final record = SourceAccountRecord(
        account: account,
        profiles: [
          SourceProfile(
            id: session.userId,
            accountId: accountId,
            name: session.userName,
            isOwner: session.isAdmin,
          ),
        ],
        servers: [
          SourceServer(
            id: info.id,
            accountId: accountId,
            profileId: session.userId,
            name: info.name,
            connections: jellyfinConnections(base, info.localAddress),
          ),
        ],
        addedAtMs: existing?.addedAtMs ?? DateTime.now().millisecondsSinceEpoch,
      );
      await ref.read(sourceRecordsProvider.notifier).putAccount(record);
      final source = record.sources.single.id;
      ref.invalidate(mediaSourceProvider(source));
      ref.read(selectedSourceIdProvider.notifier).select(source);
      if (ref.mounted) state = JellyfinSignedIn(source);
    } on SourceException {
      rethrow;
    } catch (_) {
      // Secure storage or the record store failed after the server answered.
      throw const SourceException.server(
        'Could not save this server on this device.',
      );
    }
  }
}

final jellyfinSignInProvider = NotifierProvider.autoDispose
    .family<JellyfinSignInController, JellyfinSignInState, String?>(
  JellyfinSignInController.new,
);
