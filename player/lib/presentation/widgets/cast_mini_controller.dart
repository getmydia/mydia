import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/auth/auth_status.dart';
import '../../core/cast/cast_backend.dart';
import '../../core/cast/cast_providers.dart';
import '../../core/cast/cast_seek.dart';
import '../../core/cast/cast_target.dart';
import '../../core/graphql/graphql_provider.dart';
import '../../core/router/navigator_keys.dart';
import '../../domain/models/cast_device.dart';
import 'cast_actions.dart';
import 'cast_subtitle_sheet.dart';

/// Mounts [CastMiniController] at the bottom of [child], floating above it.
///
/// `app.dart` wraps the router's output in this, which is what puts the bar on
/// every screen — and also puts it outside the Navigator the router builds,
/// and therefore outside that Navigator's Overlay. Material widgets in the bar
/// need one: each IconButton's tooltip asserts "No Overlay widget found" and
/// is replaced by a 100000px error box, which then overflows the bar's Row. So
/// the layer carries an Overlay of its own. (Dialogs still need a Navigator,
/// which no Overlay provides — see [_CastMiniControllerState._confirmStop].)
///
/// The layer is full-screen rather than a strip pinned to the bottom so
/// tooltips have somewhere to lay out; an Overlay only as tall as the bar
/// clamps them back on top of it.
class CastBarLayer extends StatelessWidget {
  const CastBarLayer({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        // Neither the Overlay nor the Align hit-tests its own empty space, so
        // everything outside the bar still reaches `child` below.
        Positioned.fill(
          child: Overlay.wrap(
            child: const Align(
              alignment: Alignment.bottomCenter,
              child: CastMiniController(),
            ),
          ),
        ),
      ],
    );
  }
}

/// The sole cast control surface, shown at the bottom of every screen.
///
/// Displays the currently playing media title, a draggable scrubber, skip
/// and play/pause/stop controls, an idle state (connected to a receiver with
/// no media loaded on it yet — see `CastConnectionState.connected` with a
/// null `mediaInfo`) and the stale-session state (the receiver dropped off
/// the network). The offline row — a target set (`castTargetProvider`) with
/// no session behind it at all — is a separate state from idle; see
/// `_buildOffline`. There is no separate full-screen remote: everything the
/// user can do while casting lives here.
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
      // A remembered device with no session at all: a connect that failed.
      content = target == null ? null : _buildOffline(target);
    } else if (session.connectionState == CastConnectionState.connecting) {
      content = _buildConnecting(session.device);
    } else if (session.isStale) {
      // The media reconnect re-casts what was playing. With no media there is
      // nothing to re-cast, so a media-less drop gets a plain reconnect.
      content = session.mediaInfo == null
          ? _buildOffline(session.device)
          : _buildStale(session);
    } else if (session.mediaInfo == null) {
      content = _buildIdle(session.device);
    } else {
      content = _buildPlaying(session);
    }

    if (content == null) return const SizedBox.shrink();
    return SafeArea(top: false, child: content);
  }

  /// Shared chrome for the three text-only rows.
  Widget _barRow({
    required Widget leading,
    required String label,
    required List<Widget> actions,
  }) {
    return Material(
      elevation: 8,
      color: Theme.of(context).colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: Theme.of(context).textTheme.bodyMedium,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ...actions,
          ],
        ),
      ),
    );
  }

  /// Connected, nothing loaded. "Ready to play on" rather than "Will play on":
  /// this is a statement about a connection that exists, not a promise about
  /// the future.
  Widget _buildIdle(CastDevice device) {
    return _barRow(
      leading: const Icon(Icons.cast_connected, color: Colors.blue, size: 24),
      label: 'Ready to play on ${device.name}',
      actions: [
        IconButton(
          key: const Key('cast-bar-idle-clear'),
          icon: const Icon(Icons.close),
          // This bar is the only cast surface in the app, so an unlabelled
          // icon here leaves a screen-reader user no route to the control at
          // all — there is no longer a full-screen remote to fall back to.
          // Same reasoning for every button below.
          tooltip: 'Stop casting to ${device.name}',
          onPressed: _stopCasting,
        ),
      ],
    );
  }

  Widget _buildConnecting(CastDevice device) {
    return _barRow(
      leading: const SizedBox(
        width: 24,
        height: 24,
        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.blue),
      ),
      label: 'Connecting to ${device.name}…',
      actions: [
        IconButton(
          key: const Key('cast-bar-connecting-cancel'),
          icon: const Icon(Icons.close),
          tooltip: 'Cancel connecting to ${device.name}',
          // Tears down whatever the in-flight connect established rather than
          // merely forgetting the device.
          onPressed: _stopCasting,
        ),
      ],
    );
  }

  /// A device is remembered but nothing is connected — a failed connect, or a
  /// receiver that idle-timed-out while the user browsed.
  Widget _buildOffline(CastDevice device) {
    return _barRow(
      leading: const Icon(Icons.cast, color: Colors.blue, size: 24),
      label: '${device.name} — not connected',
      actions: [
        FilledButton(
          key: const Key('cast-bar-offline-reconnect'),
          onPressed: () => _reconnectIdle(device),
          child: const Text('Reconnect'),
        ),
        const SizedBox(width: 8),
        IconButton(
          key: const Key('cast-bar-offline-clear'),
          icon: const Icon(Icons.close),
          tooltip: 'Forget ${device.name}',
          onPressed: _stopCasting,
        ),
      ],
    );
  }

  /// Re-open a media-less connection.
  ///
  /// Deliberately not `_reconnectStaleSession`: that re-casts the stored
  /// media, and this row exists precisely because there is none.
  Future<void> _reconnectIdle(CastDevice device) async {
    if (!mounted) return;
    try {
      final manager = await ref.read(castSessionManagerProvider.future);
      await manager.connectTo(device);
    } on CastBackendException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(castErrorMessage(e, ref: ref)),
        backgroundColor: Colors.red,
      ));
    } catch (e) {
      debugPrint('[CastMiniController] Unexpected error reconnecting: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to connect: $e'),
        backgroundColor: Colors.red,
      ));
    }
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
                  tooltip: 'Back 10 seconds',
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
                  tooltip: isPlaying ? 'Pause' : 'Play',
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
                  tooltip: 'Forward 10 seconds',
                  onPressed: () async {
                    final manager =
                        await ref.read(castSessionManagerProvider.future);
                    await manager.seek(clampSeekTarget(
                      info.position + const Duration(seconds: 10),
                      info.duration,
                    ));
                  },
                ),
                if (session.subtitles.isNotEmpty)
                  IconButton(
                    key: const Key('cast-bar-subtitles'),
                    tooltip: 'Subtitles',
                    icon: Icon(
                      session.selectedSubtitle == null
                          ? Icons.closed_caption_off
                          : Icons.closed_caption,
                    ),
                    onPressed: () => _pickSubtitle(session),
                  ),
                IconButton(
                  key: const Key('cast-bar-stop'),
                  icon: const Icon(Icons.stop, size: 28),
                  tooltip: 'Stop casting',
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
      showCastErrorSnackBar(context, e, ref: ref);
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
  ///
  /// Also clears `castTargetProvider`: stopping a cast is a clear signal
  /// that the user wants to stop casting, and a lingering target would make
  /// the *next* playback silently cast again. This is the only place a live
  /// session's stop reaches the target — `cast_actions.dart` can set a
  /// target while a session is active (re-targeting with nothing persisted
  /// behind it), and the idle ✕ is not shown in that window, so this is
  /// also the only way to clear it until the session ends.
  Future<void> _stopCasting() async {
    if (!mounted) return;
    try {
      final manager = await ref.read(castSessionManagerProvider.future);
      await manager.stopCast();
      if (!mounted) return;
      ref.read(castTargetProvider.notifier).clear();
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
    // `app.dart` mounts this bar above the router so it floats over every
    // route, which leaves its own context without a Navigator to push a
    // dialog onto. Push onto the router's root navigator instead. The
    // fallback is for widget tests, which pump the bar under a plain
    // MaterialApp that has a Navigator of its own and no router.
    final dialogContext = rootNavigatorKey.currentContext ?? context;

    final shouldStop = await showDialog<bool>(
      context: dialogContext,
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

  /// Opens the caption picker and applies whatever it resolved to.
  ///
  /// The tracks and current selection come straight off [session] rather
  /// than being reconstructed, so [CastSessionManager.selectSubtitle]
  /// always receives the very track instance the session holds (see
  /// `cast_subtitle_sheet.dart`'s [CastSubtitlePicked] doc for why that
  /// matters). A dismissal of the sheet leaves the receiver untouched.
  Future<void> _pickSubtitle(CastSession session) async {
    final choice = await showCastSubtitleSheet(
      context,
      tracks: session.subtitles,
      selected: session.selectedSubtitle,
    );

    if (!mounted) return;

    final manager = await ref.read(castSessionManagerProvider.future);
    switch (choice) {
      case CastSubtitlePicked(:final track):
        await manager.selectSubtitle(track);
      case CastSubtitleOff():
        await manager.selectSubtitle(null);
      case CastSubtitleCancelled():
        break;
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
