import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/auth/auth_status.dart';
import '../../core/cast/cast_providers.dart';
import '../../core/graphql/graphql_provider.dart';
import '../../domain/models/cast_device.dart';

/// Mini controller that shows at the bottom of the screen during casting.
///
/// Displays the currently playing media title, progress, and basic controls.
/// Tapping it navigates to the full player screen with remote controls.
class CastMiniController extends ConsumerWidget {
  const CastMiniController({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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

    final isCasting = ref.watch(isCastingProvider);
    if (!isCasting) return const SizedBox.shrink();

    final managerAsync = ref.watch(castSessionManagerProvider);
    final manager = managerAsync.value;
    if (manager == null) return const SizedBox.shrink();

    final mediaInfo = ref.watch(castMediaInfoProvider);
    final playbackState = ref.watch(castPlaybackStateProvider);
    final device = ref.watch(currentCastDeviceProvider);

    if (mediaInfo == null) {
      return const SizedBox.shrink();
    }

    final isPlaying = playbackState == CastPlaybackState.playing;
    final progress = mediaInfo.duration.inSeconds > 0
        ? mediaInfo.position.inSeconds / mediaInfo.duration.inSeconds
        : 0.0;

    // Deliberately not tappable: the full remote lives on the player screen,
    // and this bar has no media ids to route there with. An affordance that
    // only apologises for itself is worse than no affordance — the play/pause
    // and stop buttons below are the real controls.
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
            // Progress bar
            LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.grey[300],
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.red),
              minHeight: 2,
            ),
            // Controller content
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Row(
                children: [
                  // Cast icon
                  const Icon(
                    Icons.cast_connected,
                    color: Colors.blue,
                    size: 24,
                  ),
                  const SizedBox(width: 12),
                  // Media info
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          mediaInfo.title,
                          style:
                              Theme.of(context).textTheme.bodyMedium?.copyWith(
                                    fontWeight: FontWeight.w600,
                                  ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        if (device != null)
                          Text(
                            'Casting to ${device.name}',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: Colors.grey[600],
                                    ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // Play/pause button
                  IconButton(
                    icon: Icon(
                      isPlaying ? Icons.pause : Icons.play_arrow,
                      size: 28,
                    ),
                    onPressed: () async {
                      if (isPlaying) {
                        await manager.pause();
                      } else {
                        await manager.play();
                      }
                    },
                  ),
                  // Stop/disconnect button
                  IconButton(
                    icon: const Icon(
                      Icons.stop,
                      size: 28,
                    ),
                    onPressed: () async {
                      // Show confirmation dialog
                      final shouldStop = await showDialog<bool>(
                        context: context,
                        builder: (context) => AlertDialog(
                          title: const Text('Stop Casting'),
                          content: const Text(
                            'Do you want to stop casting and disconnect?',
                          ),
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
                        await manager.stopCast();
                      }
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
