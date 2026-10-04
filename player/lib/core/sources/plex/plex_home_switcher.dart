/// Plex Home: which users the account has, and making one of them the
/// account's active user.
///
/// Only the active user's tokens are kept. Every switch asks plex.tv again,
/// so a protected user's PIN is checked every time.
library;

import 'package:flutter/foundation.dart';

import '../../../domain/sources/source_error.dart';
import '../source.dart';
import '../sources_providers.dart';
import '../store/source_records.dart';
import '../store/source_secrets.dart';
import 'plex_tv_client.dart';

class PlexHomeSwitcher {
  PlexHomeSwitcher({
    required PlexTvClient tv,
    required SourceSecrets secrets,
    required SourceRecordsNotifier records,
  })  : _tv = tv,
        _secrets = secrets,
        _records = records;

  static const noServersMessage =
      'This user has no access to the servers on this account.';

  final PlexTvClient _tv;
  final SourceSecrets _secrets;
  final SourceRecordsNotifier _records;

  Future<String> _adminToken(ProviderAccount account) async {
    final token = await _secrets.accountToken(account);
    if (token == null) throw const SourceException.unauthorized();
    return token;
  }

  /// The account's Home users, fresh from plex.tv, also stored as its
  /// profiles. Empty, and nothing stored, when the account has no Home.
  Future<List<PlexHomeUser>> refreshProfiles(ProviderAccount account) async {
    final users = await _tv.homeUsers(await _adminToken(account));
    if (users.isEmpty) return users;
    await _records.updateRecord(account.id, (current) async {
      final fresh = [for (final u in users) u.toProfile(account.id)];
      final active = current.account.activeProfileId;
      // The active user stays listed even when plex.tv no longer has them:
      // the stored servers point at that profile.
      final kept = fresh.any((p) => p.id == active)
          ? fresh
          : [...fresh, ...current.profiles.where((p) => p.id == active)];
      return current.copyWith(profiles: kept);
    });
    return users;
  }

  /// Makes [user] the account's active Home user and answers the source to
  /// show next: server [serverId] under the new user when they can see it,
  /// otherwise their first server.
  Future<SourceId> switchTo(
    ProviderAccount account,
    PlexHomeUser user, {
    String? pin,
    String? serverId,
  }) async {
    final userToken =
        await _tv.switchUser(await _adminToken(account), user.uuid, pin: pin);
    final resources = await _tv.servers(userToken);
    final profileId = user.profileId;

    String? previousProfile;
    var previousServers = const <SourceServer>[];
    final written = <String>[];
    var wroteUserToken = false;
    final SourceAccountRecord? next;
    try {
      next = await _records.updateRecord(account.id, (current) async {
        final chosen = current.chosenServers.toSet();
        final visible = [
          for (final r in resources)
            if (chosen.contains(r.clientIdentifier)) r,
        ];
        if (visible.isEmpty) {
          throw const SourceException.unsupported(noServersMessage);
        }
        previousProfile = current.account.activeProfileId;
        previousServers = current.servers;

        // Tokens first: a stored server without its token would fail
        // every request.
        await _secrets.writeUserToken(account, profileId, userToken);
        wroteUserToken = true;
        for (final r in visible) {
          await _secrets.writeServerToken(
            account: account,
            profileId: profileId,
            serverId: r.clientIdentifier,
            token: r.accessToken,
          );
          written.add(r.clientIdentifier);
        }
        return current.copyWith(
          account: current.account
              .copyWith(activeProfileId: profileId, needsReauth: false),
          profiles: current.profiles.any((p) => p.id == profileId)
              ? current.profiles
              : [...current.profiles, user.toProfile(account.id)],
          servers: [
            for (final r in visible)
              r.toServer(accountId: account.id, profileId: profileId),
          ],
          chosenServerIds: current.chosenServers,
        );
      });
    } catch (_) {
      if (previousProfile != null && previousProfile != profileId) {
        await _forget(account, profileId, written, wroteUserToken);
      }
      rethrow;
    }
    if (next == null) throw const SourceException.notFound();

    final previous = previousProfile;
    if (previous != null) {
      final stillVisible = {for (final s in next.servers) s.id};
      final sameUser = previous == profileId;
      await _forget(
        account,
        previous,
        [
          for (final s in previousServers)
            if (!sameUser || !stillVisible.contains(s.id)) s.id,
        ],
        !sameUser,
      );
    }

    final sources = next.sources;
    return (sources.where((s) => s.server.id == serverId).firstOrNull ??
            sources.first)
        .id;
  }

  /// Best effort, each delete on its own: a token left behind under an
  /// inactive profile is never read, and removing the account deletes every
  /// profile's tokens.
  Future<void> _forget(ProviderAccount account, String profileId,
      List<String> serverIds, bool userToken) async {
    for (final id in serverIds) {
      try {
        await _secrets.deleteServerToken(
            account: account, profileId: profileId, serverId: id);
      } catch (e) {
        debugPrint('[Sources] Could not delete a Plex Home server token: $e');
      }
    }
    if (!userToken) return;
    try {
      await _secrets.deleteUserToken(account, profileId);
    } catch (e) {
      debugPrint('[Sources] Could not delete a Plex Home user token: $e');
    }
  }
}
