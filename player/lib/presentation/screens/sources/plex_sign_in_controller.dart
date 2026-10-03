/// The plex.tv PIN flow: show a code, wait for the viewer to approve it at
/// plex.tv/link, then let them choose which of the account's servers to
/// add.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/sources/plex/plex_identity.dart';
import '../../../core/sources/plex/plex_tv_client.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/source_factories.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../core/sources/store/source_records.dart';
import '../../../core/sources/store/source_secrets.dart';
import '../../../domain/sources/source_error.dart';

final plexTvClientProvider =
    FutureProvider<PlexTvClient>((ref) async => PlexTvClient(
          http: ref.watch(sourceHttpProvider),
          identity: await ref.watch(plexIdentityProvider.future),
        ));

final plexPinPollIntervalProvider =
    Provider<Duration>((ref) => const Duration(seconds: 2));

sealed class PlexSignInState {
  const PlexSignInState();
}

final class PlexSignInStarting extends PlexSignInState {
  const PlexSignInStarting();
}

final class PlexSignInWaiting extends PlexSignInState {
  const PlexSignInWaiting(this.code);
  final String code;
}

final class PlexSignInChoosing extends PlexSignInState {
  const PlexSignInChoosing({required this.servers, required this.chosen});
  final List<PlexResource> servers;
  final Set<String> chosen;
}

final class PlexSignInSaving extends PlexSignInState {
  const PlexSignInSaving();
}

final class PlexSignInDone extends PlexSignInState {
  const PlexSignInDone(this.firstSource);
  final SourceId? firstSource;
}

final class PlexSignInFailed extends PlexSignInState {
  const PlexSignInFailed(this.message);
  final String message;
}

class PlexSignInController extends Notifier<PlexSignInState> {
  PlexSignInController(this.reauthAccountId);

  /// Set when signing in again to an account that already exists: its id,
  /// namespace and add date are kept, its tokens replaced.
  final String? reauthAccountId;

  /// plex.tv expires a PIN after about fifteen minutes.
  static const _pinLifetime = Duration(minutes: 15);

  Timer? _poll;
  DateTime? _deadline;
  bool _checking = false;
  String? _token;
  PlexUser? _user;

  @override
  PlexSignInState build() {
    ref.onDispose(() => _poll?.cancel());
    return const PlexSignInStarting();
  }

  Future<void> start() async {
    _poll?.cancel();
    state = const PlexSignInStarting();
    try {
      final tv = await ref.read(plexTvClientProvider.future);
      final pin = await tv.createPin();
      if (!ref.mounted) return;
      state = PlexSignInWaiting(pin.code);
      _deadline = DateTime.now().add(_pinLifetime);
      _poll = Timer.periodic(
        ref.read(plexPinPollIntervalProvider),
        (_) => unawaited(_check(tv, pin.id)),
      );
    } on SourceException catch (e) {
      if (ref.mounted) state = PlexSignInFailed(e.viewerMessage);
    }
  }

  Future<void> _check(PlexTvClient tv, int pinId) async {
    if (_checking || !ref.mounted) return;
    _checking = true;
    try {
      if (DateTime.now().isAfter(_deadline!)) {
        _poll?.cancel();
        state = const PlexSignInFailed(
            'The code expired. Start again for a new one.');
        return;
      }
      final token = await tv.checkPin(pinId);
      if (token == null || !ref.mounted) return;
      _poll?.cancel();
      _token = token;
      _user = await tv.user(token);
      final servers = await tv.servers(token);
      if (!ref.mounted) return;
      state = servers.isEmpty
          ? const PlexSignInFailed('This Plex account has no servers.')
          : PlexSignInChoosing(
              servers: servers,
              chosen: {for (final s in servers) s.clientIdentifier},
            );
    } on SourceException catch (e) {
      _poll?.cancel();
      if (ref.mounted) state = PlexSignInFailed(e.viewerMessage);
    } finally {
      _checking = false;
    }
  }

  void toggle(String serverId) {
    final current = state;
    if (current is! PlexSignInChoosing) return;
    final chosen = {...current.chosen};
    if (!chosen.remove(serverId)) chosen.add(serverId);
    state = PlexSignInChoosing(servers: current.servers, chosen: chosen);
  }

  Future<void> save() async {
    final current = state;
    final token = _token;
    final user = _user;
    if (current is! PlexSignInChoosing ||
        token == null ||
        user == null ||
        current.chosen.isEmpty) {
      return;
    }
    state = const PlexSignInSaving();
    try {
      final snapshot = await ref.read(sourceRecordsProvider.future);
      final existing = reauthAccountId == null
          ? null
          : snapshot.accounts
              .where((a) => a.account.id == reauthAccountId)
              .firstOrNull;
      final accountId =
          existing?.account.id ?? const Uuid().v4().replaceAll('-', '');
      final account = existing?.account
              .copyWith(displayName: user.username, needsReauth: false) ??
          ProviderAccount(
            id: accountId,
            kind: SourceKind.plex,
            displayName: user.username,
            storageNamespace: SourceSecrets.newStorageNamespace(accountId),
            activeProfileId: 'owner',
          );
      final chosen = [
        for (final r in current.servers)
          if (current.chosen.contains(r.clientIdentifier)) r,
      ];

      // Tokens first: a stored server without its token would show up in
      // the switcher and fail every request.
      final secrets = ref.read(sourceSecretsProvider);
      await secrets.writeAccountToken(account, token);
      for (final r in chosen) {
        await secrets.writeServerToken(
          account: account,
          profileId: 'owner',
          serverId: r.clientIdentifier,
          token: r.accessToken,
        );
      }

      final record = SourceAccountRecord(
        account: account,
        profiles: [
          SourceProfile(
              id: 'owner',
              accountId: accountId,
              name: user.title,
              isOwner: true),
        ],
        servers: [
          for (final r in chosen)
            r.toServer(accountId: accountId, profileId: 'owner'),
        ],
        addedAtMs: existing?.addedAtMs ?? DateTime.now().millisecondsSinceEpoch,
      );
      await ref.read(sourceRecordsProvider.notifier).putAccount(record);
      // A re-auth that no longer lists a server leaves its token behind:
      // nothing would ever read or delete it again.
      if (existing != null) {
        final kept = {for (final s in record.servers) (s.profileId, s.id)};
        for (final dropped in existing.servers) {
          if (kept.contains((dropped.profileId, dropped.id))) continue;
          await secrets.deleteServerToken(
            account: account,
            profileId: dropped.profileId,
            serverId: dropped.id,
          );
        }
      }
      // A live source caches its token; rebuild it so it reads the new one.
      for (final source in record.sources) {
        ref.invalidate(mediaSourceProvider(source.id));
      }
      final first = record.sources.firstOrNull?.id;
      if (first != null) {
        ref.read(selectedSourceIdProvider.notifier).select(first);
      }
      if (ref.mounted) state = PlexSignInDone(first);
    } on SourceException catch (e) {
      if (ref.mounted) state = PlexSignInFailed(e.viewerMessage);
    } catch (_) {
      if (ref.mounted) {
        state = const PlexSignInFailed(
            'Could not save this account on this device.');
      }
    }
  }
}

final plexSignInProvider = NotifierProvider.autoDispose
    .family<PlexSignInController, PlexSignInState, String?>(
        PlexSignInController.new);
