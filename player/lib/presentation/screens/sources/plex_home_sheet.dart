/// Lists a Plex account's Home users and makes the picked one active,
/// asking for a PIN when the user has one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/sources/plex/plex_providers.dart';
import '../../../core/sources/plex/plex_tv_client.dart';
import '../../../core/sources/source.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/source_error.dart';
import '../../widgets/toast/toaster.dart';
import 'plex_pin_dialog.dart';

/// [onSwitched] gets the source to show next, after the sheet has closed.
/// [serverId] is the server the viewer is on, kept when the new user can
/// see it.
Future<void> showPlexHomeSheet(
  BuildContext context, {
  required ProviderAccount account,
  String? serverId,
  required ValueChanged<SourceId> onSwitched,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _PlexHomeSheet(
          account: account, serverId: serverId, onSwitched: onSwitched),
    );

class _PlexHomeSheet extends ConsumerStatefulWidget {
  const _PlexHomeSheet({
    required this.account,
    required this.serverId,
    required this.onSwitched,
  });

  final ProviderAccount account;
  final String? serverId;
  final ValueChanged<SourceId> onSwitched;

  @override
  ConsumerState<_PlexHomeSheet> createState() => _PlexHomeSheetState();
}

class _PlexHomeSheetState extends ConsumerState<_PlexHomeSheet> {
  late final Future<List<PlexHomeUser>> _users = _load();
  bool _busy = false;

  Future<List<PlexHomeUser>> _load() async {
    final switcher = await ref.read(plexHomeSwitcherProvider.future);
    return switcher.refreshProfiles(widget.account);
  }

  Future<void> _pick(PlexHomeUser user) async {
    if (_busy) return;
    final toaster = Toaster.of(context);
    final navigator = Navigator.of(context);
    final switcher = await ref.read(plexHomeSwitcherProvider.future);
    if (!mounted) return;
    setState(() => _busy = true);

    SourceId? next;
    Object? failure;
    Future<void> run(String? pin) async {
      next = await switcher.switchTo(widget.account, user,
          pin: pin, serverId: widget.serverId);
    }

    if (user.protected) {
      final done = await showPlexPinDialog(context, userName: user.title,
          submit: (pin) async {
        try {
          await run(pin);
        } on SourceException catch (e) {
          if (e.kind == SourceErrorKind.wrongPin) return e.viewerMessage;
          failure = e;
        } catch (e) {
          failure = e;
        }
        return null;
      });
      if (!done) {
        if (mounted) setState(() => _busy = false);
        return;
      }
    } else {
      try {
        await run(null);
      } catch (e) {
        failure = e;
      }
    }

    final target = next;
    if (failure != null || target == null) {
      final error = failure;
      toaster.show(
        error is SourceException
            ? error.viewerMessage
            : 'Could not switch to ${user.title}.',
        kind: ToastKind.error,
      );
      if (mounted) setState(() => _busy = false);
      return;
    }
    if (!mounted) return;
    // A live source caches its token; rebuild the account's sources so
    // they read the new user's.
    for (final source in ref.read(sourcesProvider)) {
      if (source.account.id == widget.account.id) {
        ref.invalidate(mediaSourceProvider(source.id));
      }
    }
    ref.read(selectedSourceIdProvider.notifier).select(target);
    navigator.pop();
    widget.onSwitched(target);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activeId = ref
            .watch(sourcesProvider)
            .where((s) => s.account.id == widget.account.id)
            .firstOrNull
            ?.account
            .activeProfileId ??
        widget.account.activeProfileId;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text('Switch user', style: theme.textTheme.titleMedium),
            ),
            FutureBuilder<List<PlexHomeUser>>(
              future: _users,
              builder: (context, snapshot) {
                if (snapshot.hasError) {
                  return const Padding(
                    key: Key('plex-home-error'),
                    padding: EdgeInsets.all(24),
                    child: Text("Could not load this account's users."),
                  );
                }
                final users = snapshot.data;
                if (users == null) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final user in users)
                      ListTile(
                        key: Key('plex-home-user-${user.profileId}'),
                        enabled: !_busy,
                        leading: CircleAvatar(
                          child: Text(user.title.isEmpty
                              ? '?'
                              : user.title.characters.first.toUpperCase()),
                        ),
                        title: Text(user.title),
                        selected: user.profileId == activeId,
                        trailing: user.protected
                            ? const Icon(Icons.lock_rounded)
                            : null,
                        onTap: () => _pick(user),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
