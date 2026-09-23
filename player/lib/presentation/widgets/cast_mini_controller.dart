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
import '../../core/remote/ambient_dismissals.dart';
import '../../core/remote/ambient_targets.dart';
import '../../core/remote/load_content_navigation.dart';
import '../../core/remote/remote_control_intent.dart';
import '../../core/router/navigator_keys.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/cast_device.dart';
import '../../core/p2p/p2p_service.dart' show p2pStatusNotifierProvider;
import '../../core/playback/local_playback_state.dart';
import '../screens/episode/episode_detail_controller.dart';
import '../screens/movie/movie_detail_controller.dart';
import 'cast_actions.dart';
import 'cast_bar/cast_bar_parts.dart';
import 'cast_bar/cast_pill.dart';
import 'cast_bar/dock_extents.dart';
import 'cast_subtitle_sheet.dart';
import 'toast/toast_obstruction.dart';
import 'toast/toaster.dart';

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
///
/// Also owns the [DockExtents] both the bar and `AppShell`'s dock report
/// their heights into: the bar sits above the dock rather than painting over
/// it, and floats at the window edge when there is no dock at all.
class CastBarLayer extends StatefulWidget {
  const CastBarLayer({super.key, required this.child});

  final Widget child;

  @override
  State<CastBarLayer> createState() => _CastBarLayerState();
}

class _CastBarLayerState extends State<CastBarLayer> {
  double _dock = 0;
  double _castBar = 0;

  void _setDock(double height) {
    if (!mounted || height == _dock) return;
    setState(() => _dock = height);
  }

  void _setCastBar(double height) {
    if (!mounted || height == _castBar) return;
    setState(() => _castBar = height);
  }

  @override
  Widget build(BuildContext context) {
    final hasDock = _dock > 0;
    return DockExtents(
      dock: _dock,
      castBar: _castBar,
      onDock: _setDock,
      onCastBar: _setCastBar,
      child: Stack(
        children: [
          widget.child,
          // Neither the Overlay nor the Align hit-tests its own empty space,
          // so everything outside the bar still reaches `child` below.
          Positioned.fill(
            child: Overlay.wrap(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  // Above the dock when there is one. The dock's height
                  // already includes the home indicator inset, so the bar
                  // drops its own SafeArea bottom in that case.
                  padding: EdgeInsets.only(
                    bottom: hasDock ? _dock + DockExtents.gap : 12,
                  ),
                  child: MediaQuery.removePadding(
                    context: context,
                    removeBottom: hasDock,
                    child: const CastMiniController(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
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

  Widget? _buildContent() {
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
    if (!capabilities.any && !hasMydia) return null;

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
    if (auth.value != AuthStatus.authenticated) return null;

    final session = ref.watch(castSessionProvider).value;
    final target = ref.watch(castTargetProvider);
    final isLocalPlaying = ref.watch(localPlaybackActiveProvider);

    final Widget? content;
    if (session == null) {
      if (isLocalPlaying) return null;
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

    return content;
  }

  @override
  Widget build(BuildContext context) {
    final content = _buildContent();
    return ReportedHeight(
      onHeight: DockExtents.reporterOf(context)?.onCastBar,
      child: content == null
          ? const SizedBox.shrink()
          : ToastObstruction(
              edge: ToastEdge.bottom,
              child: SafeArea(top: false, child: content),
            ),
    );
  }

  /// Shared close/cancel control for the idle, connecting, offline and
  /// ambient rows.
  Widget _closeButton({
    required Key key,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      key: key,
      icon: const Icon(Icons.close, size: 18),
      color: AppColors.textSecondary,
      // This bar is the only cast surface in the app, so an unlabelled icon
      // here leaves a screen-reader user no route to the control at all —
      // there is no longer a full-screen remote to fall back to. Same
      // reasoning for every button below.
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }

  /// Connected, nothing loaded. "Ready to play on" rather than "Will play on":
  /// this is a statement about a connection that exists, not a promise about
  /// the future.
  Widget _buildIdle(CastDevice device) => CastPill(
        child: CastBarRow(
          leading: const CastIconTile(
              accent: true, child: Icon(Icons.cast_connected)),
          title: 'Ready to play on ${device.name}',
          status: 'Connected',
          dot: CastDot.live,
          actions: [
            _closeButton(
              key: const Key('cast-bar-idle-clear'),
              tooltip: 'Stop casting to ${device.name}',
              onPressed: _stopCasting,
            ),
          ],
        ),
      );

  Widget _buildConnecting(CastDevice device) => CastPill(
        child: CastBarRow(
          leading: const CastIconTile(
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                  strokeWidth: 2, color: AppColors.primary),
            ),
          ),
          title: 'Connecting to ${device.name}…',
          actions: [
            _closeButton(
              key: const Key('cast-bar-connecting-cancel'),
              tooltip: 'Cancel connecting to ${device.name}',
              // Tears down whatever the in-flight connect established rather
              // than merely forgetting the device.
              onPressed: _stopCasting,
            ),
          ],
        ),
      );

  /// A device is remembered but nothing is connected — a failed connect, or a
  /// receiver that idle-timed-out while the user browsed.
  Widget _buildOffline(CastDevice device) => CastPill(
        child: CastBarRow(
          leading: const CastIconTile(child: Icon(Icons.cast)),
          title: device.name,
          status: 'Not connected',
          dot: CastDot.idle,
          actions: [
            CastPrimaryAction(
              key: const Key('cast-bar-offline-reconnect'),
              label: 'Reconnect',
              onPressed: () => _reconnectIdle(device),
            ),
            _closeButton(
              key: const Key('cast-bar-offline-clear'),
              tooltip: 'Forget ${device.name}',
              onPressed: _stopCasting,
            ),
          ],
        ),
      );

  /// "Playing on Living Room" for a paired player already mid-watch that
  /// nobody asked this device to track — from [ambientPlayingProvider]
  /// (`AmbientTargets`, `core/remote/ambient_targets.dart`). Null when there
  /// is nothing ambient to show, which is the ordinary case: most of the
  /// time no other paired device is playing anything at all.
  ///
  /// Only ever one row, the first target held: a user with more than one
  /// other device mid-watch at once is a corner the picker already covers,
  /// and this banner's whole point is a glanceable nudge, not a second
  /// picker. Shows the first held target that is neither this device nor
  /// dismissed.
  Widget? _buildAmbient() {
    final held = ref.watch(ambientPlayingProvider).value ?? const [];
    final dismissed = ref.watch(ambientDismissalsProvider);
    final selfNodeId =
        ref.watch(p2pStatusNotifierProvider.select((s) => s.nodeId));

    final ambientTarget = held
        .where((t) =>
            selfNodeId == null ||
            t.device.id.toLowerCase() != selfNodeId.toLowerCase())
        .where((t) => !dismissed.contains(AmbientDismissal.of(t)))
        .firstOrNull;
    if (ambientTarget == null) return null;

    // `AmbientTarget.device.name` is the bare node id — the probe this came
    // from carries no display names (see that field's own dartdoc) — so
    // resolve the real one against the paired-device roster before it ever
    // reaches the label. Falls back to the id itself only in the narrow
    // window before `remoteDeviceNamesProvider` has resolved.
    final names = ref.watch(remoteDeviceNamesProvider).value ?? const {};
    final name = names[ambientTarget.device.id] ?? ambientTarget.device.id;

    return CastPill(
      child: CastBarRow(
        leading: CastThumb(imageUrl: ambientTarget.snapshot.imageUrl),
        title: ambientTarget.snapshot.title,
        status: 'Playing on $name',
        dot: CastDot.live,
        actions: [
          CastPrimaryAction(
            key: const Key('cast-bar-ambient-open'),
            label: 'View',
            onPressed: () => _openAmbientTarget(ambientTarget, name),
          ),
          _closeButton(
            key: const Key('cast-bar-ambient-dismiss'),
            tooltip: 'Hide Playing on $name',
            onPressed: () => ref
                .read(ambientDismissalsProvider.notifier)
                .dismiss(ambientTarget),
          ),
        ],
      ),
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
      showCastErrorToast(context, e, ref: ref, isMydiaTarget: true);
    } catch (e) {
      debugPrint('[CastMiniController] Unexpected error opening $name: $e');
      if (!mounted) return;
      showToast(context, 'Failed to open $name: $e', kind: ToastKind.error);
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
      showCastErrorToast(context, e,
          ref: ref, isMydiaTarget: device.protocol == CastProtocolKind.mydia);
    } catch (e) {
      debugPrint('[CastMiniController] Unexpected error reconnecting: $e');
      if (!mounted) return;
      showToast(context, 'Failed to connect: $e', kind: ToastKind.error);
    }
  }

  Widget _buildStale(CastSession session) => CastPill(
        child: CastBarRow(
          leading: CastThumb(
            imageUrl: session.mediaInfo?.imageUrl,
            fallbackIcon: Icons.cast,
            dimmed: true,
          ),
          title: session.mediaInfo?.title ?? session.device.name,
          status: 'Lost connection to ${session.device.name}',
          dot: CastDot.lost,
          actions: [
            // Re-cast what the *stale session* was playing. Anything else
            // here would silently start whatever this screen happens to be
            // showing instead.
            CastPrimaryAction(
              key: const Key('cast-stale-reconnect'),
              label: 'Reconnect',
              onPressed: _reconnectStaleSession,
            ),
            CastGhostAction(
              key: const Key('cast-stale-stop'),
              label: 'Stop',
              onPressed: _stopCasting,
            ),
          ],
        ),
      );

  Widget _buildPlaying(CastSession session) {
    final info = session.mediaInfo;
    if (info == null) return const SizedBox.shrink();

    final durationKnown = hasKnownDuration(info.duration);
    final value =
        _dragFraction ?? castProgressFraction(info.position, info.duration);
    final isPlaying = session.playbackState == CastPlaybackState.playing;

    return CastPill(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CastBarRow(
            leading: CastThumb(imageUrl: info.imageUrl),
            title: info.title,
            status: 'Casting to ${session.device.name}',
            dot: CastDot.live,
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              activeTrackColor: AppColors.primary,
              inactiveTrackColor: AppColors.textPrimary.withValues(alpha: 0.1),
              thumbColor: AppColors.textPrimary,
              overlayColor: AppColors.primary.withValues(alpha: 0.12),
              trackHeight: 4,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  Text(
                    _formatDuration(info.position),
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.textSecondary),
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
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppColors.textSecondary),
                  ),
                ],
              ),
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
                  color: AppColors.textPrimary,
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
                IconButton.filled(
                  key: const Key('cast-bar-play-pause'),
                  icon: Icon(
                    isPlaying ? Icons.pause : Icons.play_arrow,
                    size: 28,
                  ),
                  style: IconButton.styleFrom(
                    backgroundColor: AppColors.primary,
                    foregroundColor: AppColors.onPrimary,
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
                  color: AppColors.textPrimary,
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
                    color: AppColors.textPrimary,
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
                    color: AppColors.textPrimary,
                    tooltip: 'Play on this device',
                    onPressed: _pullToLocal,
                  ),
                IconButton(
                  key: const Key('cast-bar-stop'),
                  icon: const Icon(Icons.stop, size: 28),
                  color: AppColors.textPrimary,
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
        showToast(context, 'Nothing to bring over yet.');
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
          final movie = await readDetailKeepingAlive(
            ref,
            provider: movieDetailControllerProvider(id),
            future: movieDetailControllerProvider(id).future,
          );
          return LoadContentTarget(files: movie.files, title: movie.title);
        },
        fetchEpisodeTarget: (id) async {
          final episode = await readDetailKeepingAlive(
            ref,
            provider: episodeDetailControllerProvider(id),
            future: episodeDetailControllerProvider(id).future,
          );
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
      showToast(context, 'Failed to bring playback here: $e',
          kind: ToastKind.error);
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
      final target = ref.read(castTargetProvider);
      showCastErrorToast(context, e,
          ref: ref, isMydiaTarget: target?.protocol == CastProtocolKind.mydia);
    } catch (e) {
      debugPrint('[CastMiniController] Unexpected error reconnecting cast: $e');
      if (!mounted) return;
      showToast(context, 'Failed to reconnect: $e', kind: ToastKind.error);
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
      showToast(context, 'Failed to stop casting: $e', kind: ToastKind.error);
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
