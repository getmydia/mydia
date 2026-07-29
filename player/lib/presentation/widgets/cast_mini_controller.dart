import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/auth/auth_status.dart';
import '../../core/cast/cast_backend.dart';
import '../../core/cast/cast_providers.dart';
import '../../core/cast/cast_seek.dart';
import '../../core/cast/cast_target.dart';
import '../../core/graphql/graphql_provider.dart';
import '../../domain/models/cast_device.dart';
import 'cast_actions.dart';

/// The sole cast control surface, shown at the bottom of every screen.
///
/// Displays the currently playing media title, a draggable scrubber, skip
/// and play/pause/stop controls, an idle state (a target picked before
/// anything is playing — see `castTargetProvider`) and the stale-session
/// state (the receiver dropped off the network). There is no separate
/// full-screen remote: everything the user can do while casting lives here.
class CastMiniController extends ConsumerStatefulWidget {
  const CastMiniController({super.key});

  @override
  ConsumerState<CastMiniController> createState() => _CastMiniControllerState();
}

class _CastMiniControllerState extends ConsumerState<CastMiniController> {
  /// Where the user has dragged to, while they are dragging.
  ///
  /// The position stream keeps arriving mid-drag; without holding the drag
  /// value locally the thumb snaps back to the receiver's position on every
  /// tick and the bar becomes impossible to scrub.
  double? _dragFraction;

  @override
  Widget build(BuildContext context) {
    final capabilities = ref.watch(castCapabilitiesProvider);
    if (!capabilities.any) return const SizedBox.shrink();

    // Gate on authentication before touching anything else in the cast stack.
    // `isCastingProvider` reaches `castSessionManagerProvider`, whose body
    // awaits `asyncGraphqlClientProvider` — and that provider does not resolve
    // until the user is authenticated. Building the chain beforehand leaves it
    // loading indefinitely on every screen, and when the container is disposed
    // while it is still pending (app teardown, or an integration test finishing
    // on the pairing screen) Riverpod completes it with a StateError that
    // escapes as an unhandled async error. There is also nothing to show: you
    // cannot be casting before you have a server.
    final auth = ref.watch(authStateProvider);
    if (auth.value != AuthStatus.authenticated) return const SizedBox.shrink();

    final session = ref.watch(castSessionProvider).value;
    final target = ref.watch(castTargetProvider);

    final Widget? content;
    if (session == null) {
      content = target == null ? null : _buildIdle(target);
    } else if (session.isStale) {
      content = _buildStale(session);
    } else {
      content = _buildPlaying(session);
    }

    if (content == null) return const SizedBox.shrink();
    return SafeArea(top: false, child: content);
  }

  Widget _buildIdle(CastDevice device) {
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.cast, color: Colors.blue, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Will play on ${device.name}',
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            IconButton(
              key: const Key('cast-bar-idle-clear'),
              icon: const Icon(Icons.close),
              onPressed: () => ref.read(castTargetProvider.notifier).clear(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStale(CastSession session) {
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            const Icon(Icons.cast_outlined, color: Colors.grey, size: 24),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Lost connection to ${session.device.name}',
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            FilledButton(
              key: const Key('cast-stale-reconnect'),
              // Re-cast what the *stale session* was playing. Anything else
              // here would silently start whatever this screen happens to
              // be showing instead.
              onPressed: _reconnectStaleSession,
              child: const Text('Reconnect'),
            ),
            const SizedBox(width: 8),
            TextButton(
              key: const Key('cast-stale-stop'),
              onPressed: _stopCasting,
              child: const Text('Stop'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlaying(CastSession session) {
    final info = session.mediaInfo;
    if (info == null) return const SizedBox.shrink();

    final durationKnown = hasKnownDuration(info.duration);
    final value =
        _dragFraction ?? castProgressFraction(info.position, info.duration);
    final isPlaying = session.playbackState == CastPlaybackState.playing;

    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                const Icon(Icons.cast_connected, color: Colors.blue, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        info.title,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        'Casting to ${session.device.name}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Colors.grey[600],
                            ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(
              children: [
                Text(
                  _formatDuration(info.position),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Expanded(
                  child: Slider(
                    key: const Key('cast-bar-scrubber'),
                    value: value,
                    // Null disables the control outright. Leaving it live
                    // against an unknown duration resolves every drag to
                    // `fraction * -1s`, i.e. the start.
                    onChanged: durationKnown
                        ? (v) => setState(() => _dragFraction = v)
                        : null,
                    onChangeEnd: durationKnown
                        ? (v) async {
                            final target =
                                seekTargetForFraction(v, info.duration);
                            setState(() => _dragFraction = null);
                            if (target == null) return;
                            final manager = await ref
                                .read(castSessionManagerProvider.future);
                            await manager.seek(target);
                          }
                        : null,
                  ),
                ),
                Text(
                  key: const Key('cast-bar-duration'),
                  durationKnown ? _formatDuration(info.duration) : '--:--',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                IconButton(
                  key: const Key('cast-bar-rewind'),
                  icon: const Icon(Icons.replay_10),
                  onPressed: () async {
                    final manager =
                        await ref.read(castSessionManagerProvider.future);
                    await manager.seek(clampSeekTarget(
                      info.position - const Duration(seconds: 10),
                      info.duration,
                    ));
                  },
                ),
                IconButton(
                  key: const Key('cast-bar-play-pause'),
                  icon: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    size: 28,
                  ),
                  onPressed: () async {
                    final manager =
                        await ref.read(castSessionManagerProvider.future);
                    if (isPlaying) {
                      await manager.pause();
                    } else {
                      await manager.play();
                    }
                  },
                ),
                IconButton(
                  key: const Key('cast-bar-forward'),
                  icon: const Icon(Icons.forward_10),
                  onPressed: () async {
                    final manager =
                        await ref.read(castSessionManagerProvider.future);
                    await manager.seek(clampSeekTarget(
                      info.position + const Duration(seconds: 10),
                      info.duration,
                    ));
                  },
                ),
                IconButton(
                  key: const Key('cast-bar-stop'),
                  icon: const Icon(Icons.stop, size: 28),
                  onPressed: _confirmStop,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Re-cast the media the stored (now stale) session was playing.
  Future<void> _reconnectStaleSession() async {
    if (!mounted) return;
    try {
      final manager = await ref.read(castSessionManagerProvider.future);
      await manager.reconnectStoredSession();
    } on CastBackendException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(castErrorMessage(e, ref: ref)),
        backgroundColor: Colors.red,
      ));
    } catch (e) {
      debugPrint('[CastMiniController] Unexpected error reconnecting cast: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to reconnect: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  /// Drop the cast session and fall back to local playback.
  Future<void> _stopCasting() async {
    if (!mounted) return;
    try {
      final manager = await ref.read(castSessionManagerProvider.future);
      await manager.stopCast();
    } catch (e) {
      debugPrint('[CastMiniController] Unexpected error stopping cast: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to stop casting: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  Future<void> _confirmStop() async {
    final shouldStop = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Stop Casting'),
        content: const Text('Do you want to stop casting and disconnect?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Stop'),
          ),
        ],
      ),
    );

    if (shouldStop == true) {
      await _stopCasting();
    }
  }

  String _formatDuration(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60);
    final seconds = duration.inSeconds.remainder(60);

    if (hours > 0) {
      return '${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    } else {
      return '${minutes.toString().padLeft(2, '0')}:${seconds.toString().padLeft(2, '0')}';
    }
  }
}
