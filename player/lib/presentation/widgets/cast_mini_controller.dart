import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../core/auth/auth_status.dart';
import '../../core/cast/cast_backend.dart';
import '../../core/cast/cast_providers.dart';
import '../../core/cast/cast_seek.dart';
import '../../core/cast/cast_session_manager.dart' show PulledSession;
import '../../core/cast/cast_target.dart';
import '../../core/graphql/graphql_provider.dart';
import '../../core/remote/ambient_targets.dart';
import '../../core/remote/load_content_navigation.dart';
import '../../core/remote/remote_control_intent.dart';
import '../../core/router/navigator_keys.dart';
import '../../domain/models/cast_device.dart';
import '../screens/episode/episode_detail_controller.dart';
import '../screens/movie/movie_detail_controller.dart';
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
    // `capabilities` describes only Chromecast/DLNA platform entitlement.
    // A Mydia target needs none of that — it is reached over the
    // already-connected p2p host, not the platform's local-network
    // discovery — so `castDiscoveryProvider` and `cast_device_picker.dart`
    // both already keep it ungated for the same reason (see
    // `castDiscoveryProvider`'s own dartdoc in `cast_providers.dart`).
    // Gating the whole bar on `capabilities.any` alone means this never
    // mounts on a build with no other capability at all — Flutter Web,
    // `ambient_lifecycle.dart` names as this app's primary deployment —
    // which would make both the ambient "Playing on X" banner and the
    // pull-to-local button unreachable there.
    final hasMydia = ref.watch(mydiaCastBackendProvider) != null;
    if (!capabilities.any && !hasMydia) return const SizedBox.shrink();

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
      // With neither, there is nothing of this device's own to show — which
      // is exactly when an ambient banner about a *different* paired player
      // belongs: an active cast (of this device's own) already claims the
      // bar, and stacking a third party's "Playing on X" underneath it
      // would just be noise.
      content = target == null ? _buildAmbient() : _buildOffline(target);
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

  /// "Playing on Living Room" for a paired player already mid-watch that
  /// nobody asked this device to track — from [ambientPlayingProvider]
  /// (`AmbientTargets`, `core/remote/ambient_targets.dart`). Null when there
  /// is nothing ambient to show, which is the ordinary case: most of the
  /// time no other paired device is playing anything at all.
  ///
  /// Only ever one row, the first target held: a user with more than one
  /// other device mid-watch at once is a corner the picker already covers,
  /// and this banner's whole point is a glanceable nudge, not a second
  /// picker.
  Widget? _buildAmbient() {
    final held = ref.watch(ambientPlayingProvider).value ?? const [];
    if (held.isEmpty) return null;

    final ambientTarget = held.first;
    // `AmbientTarget.device.name` is the bare node id — the probe this came
    // from carries no display names (see that field's own dartdoc) — so
    // resolve the real one against the paired-device roster before it ever
    // reaches the label. Falls back to the id itself only in the narrow
    // window before `remoteDeviceNamesProvider` has resolved.
    final names = ref.watch(remoteDeviceNamesProvider).value ?? const {};
    final name = names[ambientTarget.device.id] ?? ambientTarget.device.id;

    return _barRow(
      leading: const Icon(Icons.cast, color: Colors.blue, size: 24),
      label: 'Playing on $name',
      actions: [
        TextButton(
          key: const Key('cast-bar-ambient-open'),
          onPressed: () => _openAmbientTarget(ambientTarget, name),
          child: const Text('View'),
        ),
      ],
    );
  }

  /// Connects to an ambient target, tapping through to the remote UI —
  /// `_buildPlaying` below, once the connect resolves and republishes the
  /// session with media on it.
  ///
  /// [AmbientTarget.device] carries no `nowPlayingTitle` metadata of its own
  /// (only [AmbientTargets.sweep]'s roster-wide probe sets that, on the
  /// *discovery*-shaped [CastDevice] `MydiaCastBackend._probeSequence`
  /// builds — an ambient one never goes through that path). Without it,
  /// `isPlayingMydiaTarget` would read this device as idle and connect
  /// media-less instead of adopting, showing "Ready to play on" over a
  /// receiver that is actually mid-film. [ambientTarget.snapshot] already
  /// has the one field that check needs, so this rebuilds the device with it
  /// set rather than reaching back into discovery for it.
  Future<void> _openAmbientTarget(
    AmbientTarget ambientTarget,
    String name,
  ) async {
    if (!mounted) return;

    final device = CastDevice(
      id: ambientTarget.device.id,
      name: name,
      protocol: CastProtocolKind.mydia,
      metadata: {
        'nodeId': ambientTarget.device.id,
        'nowPlayingTitle': ambientTarget.snapshot.title,
      },
    );

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
      debugPrint('[CastMiniController] Unexpected error opening $name: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to open $name: $e'),
        backgroundColor: Colors.red,
      ));
    }
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
                // Pull: only a Mydia target runs this same app, so only one
                // can hand playback back to this device at its exact
                // position. Shown for a self-started cast too, not just an
                // adopted one — bringing your own cast back is exactly as
                // valid a thing to want as pulling someone else's.
                if (session.device.protocol == CastProtocolKind.mydia)
                  IconButton(
                    key: const Key('cast-bar-pull'),
                    icon: const Icon(Icons.phone_iphone),
                    tooltip: 'Play on this device',
                    onPressed: _pullToLocal,
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

  /// Brings whatever is on the connected Mydia target back to this device.
  ///
  /// `CastSessionManager.pullToLocal` does the hard part: it reads the
  /// target's exact position from its own captured snapshot (never the
  /// interpolated position stream or throttled server progress — see that
  /// method's own dartdoc), then pauses and stops the target and ends this
  /// manager's session. What is left here is turning the
  /// [PulledSession] that comes back into an actual local playback — the
  /// same resolution an inbound remote `LoadContent` uses
  /// ([pushLoadContentDestination], `core/remote/load_content_navigation.dart`)
  /// applied to a `LoadContentIntent` built from it
  /// ([loadContentIntentForPulledSession]), so a pulled session picks the
  /// same file a local tap would.
  ///
  /// Progress reporting: `pullToLocal` is what stops the target, which is
  /// what stops it writing `updateMovieProgress`/`updateEpisodeProgress` for
  /// this item (its own local player receives the `Stop` over remote
  /// control and halts). The `PlayerScreen` this pushes into then becomes
  /// the item's only writer, exactly like any other local playback. This
  /// method itself never calls either mutation.
  Future<void> _pullToLocal() async {
    if (!mounted) return;
    try {
      final manager = await ref.read(castSessionManagerProvider.future);
      final pulled = await manager.pullToLocal();
      if (!mounted) return;

      final intent =
          pulled == null ? null : loadContentIntentForPulledSession(pulled);
      if (intent == null) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Nothing to bring over yet.'),
        ));
        return;
      }

      // A clear signal the viewer wants to watch here now, the same as
      // `_stopCasting` clearing it on an explicit stop — a lingering target
      // would silently re-cast the *next* thing played instead of keeping
      // it local.
      ref.read(castTargetProvider.notifier).clear();
      if (!mounted) return;

      // `app.dart` mounts this bar above the router's own Navigator (see
      // `CastBarLayer`'s dartdoc), so this widget's own `context` has no
      // `GoRouter` above it to find; `rootNavigatorKey.currentContext` is
      // the router's own root, same fallback `_confirmStop` already uses.
      final router = GoRouter.of(rootNavigatorKey.currentContext ?? context);
      final screenWidth =
          MediaQuery.sizeOf(rootNavigatorKey.currentContext ?? context).width;

      await pushLoadContentDestination(
        intent,
        screenWidth,
        fetchMovieTarget: (id) async {
          final movie =
              await ref.read(movieDetailControllerProvider(id).future);
          return LoadContentTarget(files: movie.files, title: movie.title);
        },
        fetchEpisodeTarget: (id) async {
          final episode =
              await ref.read(episodeDetailControllerProvider(id).future);
          return LoadContentTarget(
            files: episode.files,
            title: episode.title,
            showId: episode.show.id,
            seasonNumber: episode.seasonNumber,
          );
        },
        push: (path) => router.push(path),
      );
    } catch (e) {
      debugPrint('[CastMiniController] Unexpected error pulling session: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Failed to bring playback here: $e'),
        backgroundColor: Colors.red,
      ));
    }
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

/// The `LoadContentIntent` a pulled session should resume as, or null when
/// [pulled] has nothing playable to resume.
///
/// [PulledSession.mediaItemId] only, per that field's own dartdoc: "a
/// caller with nothing to open should treat that as there was nothing to
/// pull, not open an item with no id."
///
/// Extracted as a free function, the same precedent as
/// `player_screen.dart`'s `applyQualityChoice`/`pushToRemoteTarget`: the
/// widget path needs a live `CastSessionManager`, a resolved GraphQL
/// client, and a mounted `GoRouter` to reach this decision at all, none of
/// which a bare unit test can stand up around — but the mapping itself
/// depends on none of them.
@visibleForTesting
LoadContentIntent? loadContentIntentForPulledSession(PulledSession pulled) {
  final mediaItemId = pulled.mediaItemId;
  if (mediaItemId == null) return null;

  return LoadContentIntent(
    mediaItemId: mediaItemId,
    episodeId: pulled.episodeId,
    startAt: pulled.position,
    audioTrack: pulled.selectedAudioTrackId,
    subtitleTrack: pulled.selectedSubtitleTrackId,
    autoplay: true,
  );
}
