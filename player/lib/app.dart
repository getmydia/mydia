import 'dart:async' show StreamSubscription, unawaited;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'core/auth/auth_status.dart';
import 'core/layout/window_chrome_inset.dart';
import 'core/theme/app_theme.dart';
import 'core/providers/providers.dart';
import 'core/graphql/graphql_provider.dart';
import 'core/graphql/watch/resume_gate.dart';
import 'core/graphql/watch/watcher_registry.dart';
import 'core/cast/cast_providers.dart';
import 'core/downloads/download_providers.dart';
import 'core/downloads/download_service.dart';
import 'core/auth/device_info_service.dart';
import 'core/player/best_file.dart';
import 'core/remote/node_registration.dart';
import 'core/remote/remote_control_intent.dart';
import 'core/remote/remote_control_receiver.dart';
import 'core/remote/remote_control_settings.dart';
import 'core/remote/remote_roster.dart';
import 'core/remote/remote_target_controller.dart';
import 'core/router/navigator_keys.dart';
import 'core/scroll/app_scroll_behavior.dart';
import 'domain/models/media_file.dart';
import 'presentation/screens/episode/episode_detail_controller.dart';
import 'presentation/screens/movie/movie_detail_controller.dart';
import 'presentation/widgets/cast_mini_controller.dart';
import 'package:player/core/p2p/p2p_service.dart';
import 'package:player/native/lib.dart';

/// Everything `resolveLoadContentRoute` needs beyond the file list itself.
///
/// `title` backs `describe()`'s reporting back to controllers (it falls back
/// to 'Untitled' with nothing supplied); `showId`/`seasonNumber` are what
/// `PlayerScreen._hasNextEpisode`/`_hasPreviousEpisode` gate on — null either
/// one and a remotely-started episode's next/previous-episode capability is
/// silently dead, even though the exact same fetch this type is built from
/// already has both fields on hand. Both are null for a movie, which has
/// neither concept.
@immutable
class LoadContentTarget {
  final List<MediaFile> files;
  final String title;
  final String? showId;
  final int? seasonNumber;

  const LoadContentTarget({
    required this.files,
    required this.title,
    this.showId,
    this.seasonNumber,
  });
}

/// Fetches [LoadContentTarget] for whichever half of a `LoadContentIntent`
/// identifies content — an episode's own files/title/show context, or a
/// movie's. Kept as a function type rather than folded into
/// [resolveLoadContentRoute] directly, so a test can substitute a fake
/// fetcher and assert the resolution *decision* without a GraphQL client at
/// all.
typedef LoadContentTargetFetcher = Future<LoadContentTarget> Function(
    String id);

/// The `/player/...` route a `LoadContentIntent` should actually land on, or
/// null when nothing here resolves to a playable file.
///
/// This is the target side of the feature's primary use case: a controller
/// on another device said "play this", and this device has to turn that
/// reference into an actual stream against the server it is already paired
/// to. Resolving means fetching the right target — the episode's own,
/// never the show's, when [LoadContentIntent.episodeId] is set — then
/// running the same [pickBestFile] every local Play button uses, so a
/// remote play and a local tap never disagree about which version plays.
/// `title`/`showId`/`seasonNumber` ride along in the returned route's query
/// string exactly as `playerRouteForContinueWatching`
/// (`home_screen.dart:42-68`) already carries them for a local tap, so a
/// remotely-started episode keeps its next/previous-episode capability
/// instead of losing it.
///
/// Runs off an inbound network command with no user-facing error path, so
/// every failure here — a fetch that throws, [pickBestFile]'s own
/// device/network probe throwing — is caught and turned into null rather
/// than left to propagate. The caller's job is only to fall back to the
/// detail screen when this returns null.
Future<String?> resolveLoadContentRoute(
  LoadContentIntent intent,
  double screenWidth, {
  required LoadContentTargetFetcher fetchMovieTarget,
  required LoadContentTargetFetcher fetchEpisodeTarget,
}) async {
  final episodeId = intent.episodeId;

  try {
    final target = episodeId != null
        ? await fetchEpisodeTarget(episodeId)
        : await fetchMovieTarget(intent.mediaItemId);

    final file = await pickBestFile(target.files, screenWidth);
    if (file == null) return null;

    final type = episodeId != null ? 'episode' : 'movie';
    final id = episodeId ?? intent.mediaItemId;

    final query = <String, String>{
      'fileId': file.id,
      'title': target.title,
      'resume': intent.startAt.inSeconds.toString(),
      if (target.showId != null) 'showId': target.showId!,
      if (target.seasonNumber != null)
        'seasonNumber': target.seasonNumber.toString(),
      if (intent.audioTrack != null) 'audioTrack': intent.audioTrack!,
      if (intent.subtitleTrack != null) 'subtitleTrack': intent.subtitleTrack!,
      // Absent means the player's own default (true, i.e. play).
      if (!intent.autoplay) 'autoplay': 'false',
    };

    return Uri(path: '/player/$type/$id', queryParameters: query).toString();
  } catch (error, stackTrace) {
    debugPrint('[MyApp] Remote LoadContent resolution failed: $error');
    debugPrintStack(stackTrace: stackTrace);
    return null;
  }
}

/// The detail-screen fallback for [intent] — the same "no file chosen yet"
/// destination every other entry point in this app takes (see
/// `home_screen.dart`'s `_handlePlay`) when nothing resolves to a playable
/// file.
String loadContentDetailFallback(LoadContentIntent intent) =>
    intent.episodeId != null
        ? '/episode/${intent.episodeId}'
        : '/movie/${intent.mediaItemId}';

/// Resolves [intent] and hands [push] the destination: the resolved player
/// route, or [loadContentDetailFallback] when nothing resolves. [push] is
/// the one side effect in this function, kept as an injected callback so a
/// test can assert what gets pushed — including the fallback case, which
/// [resolveLoadContentRoute] alone cannot exercise, since returning `null`
/// from that function is the input to this decision, not the decision
/// itself — without mounting a router at all. The real app wires [push] to
/// `GoRouter.push`.
Future<void> pushLoadContentDestination(
  LoadContentIntent intent,
  double screenWidth, {
  required LoadContentTargetFetcher fetchMovieTarget,
  required LoadContentTargetFetcher fetchEpisodeTarget,
  required void Function(String path) push,
}) async {
  final path = await resolveLoadContentRoute(
    intent,
    screenWidth,
    fetchMovieTarget: fetchMovieTarget,
    fetchEpisodeTarget: fetchEpisodeTarget,
  );

  push(path ?? loadContentDetailFallback(intent));
}

/// Answers one inbound control [request], re-checking the opt-out first.
///
/// [RemoteControlReceiver] itself only knows the paired-device roster, not
/// this device's own opt-out. Re-checking per request is what makes flipping
/// the setting off refuse the very next request, instead of only taking
/// effect after a restart, and it does so without tearing down and rebuilding
/// the subscription.
///
/// Every collaborator arrives as a callback, the same way
/// [pushLoadContentDestination] takes `push`, so this is reachable from a
/// test. That is not stylistic: the startup path that builds the real
/// collaborators awaits `DeviceInfoService.getDeviceName()`, and on Linux
/// that never completes inside `testWidgets`' fake-async zone — verified by
/// probe, where it hangs indefinitely rather than throwing. So no widget test
/// can pump [MyApp] far enough to reach the subscription that calls this, and
/// the recheck would otherwise be untestable. `player_screen.dart` extracts
/// `shouldRestartForSeek` and `applyQualityChoice` for the same reason.
///
/// Nothing escapes: the caller is a stream listener with no error path of its
/// own, so a throw from either callback would surface as an unhandled async
/// error rather than anything a user could act on.
@visibleForTesting
Future<void> handleControlRequest({
  required FlutterInboundControlRequest request,
  required Future<bool> Function() controllableEnabled,
  required Future<void> Function(String, FlutterRemoteControlResponse) respond,
  required Future<void> Function(FlutterInboundControlRequest) handle,
}) async {
  try {
    if (!await controllableEnabled()) {
      await respond(
        request.requestId,
        const FlutterRemoteControlResponse_NotAuthorized(),
      );
      return;
    }
    await handle(request);
  } catch (e, stackTrace) {
    debugPrint('[MyApp] Remote control request handling failed: $e');
    debugPrintStack(stackTrace: stackTrace);
  }
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  final ResumeGate _resumeGate = ResumeGate();

  /// Subscribed once here, for the app's whole lifetime, rather than by
  /// whichever screen happens to be mounted: `LoadContent` is the one intent
  /// `RemoteTargetController` cannot hand to a player, because it is what
  /// starts a player in the first place. See
  /// `RemoteTargetController.intents`'s dartdoc.
  StreamSubscription<RemoteControlIntent>? _remoteIntentsSubscription;

  /// Subscribed once [_initRemoteControlIfEnabled] wires up a receiver.
  /// Cancelled before `P2pService.dispose` can close the stream it reads
  /// from, the same ordering `_remoteIntentsSubscription` follows relative to
  /// `RemoteTargetController`.
  StreamSubscription<FlutterInboundControlRequest>? _controlRequestSubscription;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _remoteIntentsSubscription = ref
        .read(remoteTargetControllerProvider)
        .intents
        .listen(_handleRemoteIntent);
    // Initialize P2P services
    Future.microtask(() async {
      try {
        await ref.read(p2pServiceProvider).initialize();
        // LocalProxyService is started on-demand when streaming,
        // as it requires a targetPeer parameter
      } catch (e) {
        debugPrint('[MyApp] Failed to initialize P2P: $e');
      }
    });

    // Reattach to a cast session left running by a previous app launch, on
    // builds that can actually cast.
    //
    // Deliberately gated on authentication rather than fired at startup. The
    // cast stack awaits `asyncGraphqlClientProvider`, which stays in the
    // loading state until the user is authenticated. Kicking it off before
    // then leaves that chain in flight indefinitely, and if the container is
    // disposed while it is still loading — app teardown, or an integration
    // test finishing on the pairing screen — Riverpod completes the pending
    // future with a StateError from inside `castSessionManagerProvider`'s own
    // body, where no caller can catch it. It surfaces as an unhandled async
    // error and fails the test run. Restoring a cast session before auth is
    // meaningless anyway: there is no reachable server yet.
    //
    // Starting remote control shares the same gate for the same reason:
    // `NodeRegistration` and `RemoteRoster` both need a signed-in GraphQL
    // client too.
    ref.listenManual<AsyncValue<AuthStatus>>(
      authStateProvider,
      (previous, next) {
        if (next.value != AuthStatus.authenticated) return;
        _restoreCastSession();
        unawaited(_initRemoteControlIfEnabled());
      },
      fireImmediately: true,
    );
  }

  /// Whether a restore has already been attempted this launch. Auth state can
  /// re-emit `authenticated` (a token refresh, a reconnect) and restoring is a
  /// once-per-launch action.
  bool _castRestoreAttempted = false;

  Future<void> _restoreCastSession() async {
    if (_castRestoreAttempted) return;
    if (!ref.read(castCapabilitiesProvider).any) return;
    _castRestoreAttempted = true;

    try {
      final manager = await ref.read(castSessionManagerProvider.future);
      if (!mounted) return;
      await manager.restoreSession();
    } catch (e) {
      debugPrint('[MyApp] Failed to restore cast session: $e');
    }
  }

  /// Whether the controllable-device startup path has already run this
  /// launch. Same once-per-launch reasoning as [_castRestoreAttempted]:
  /// `authStateProvider` can re-emit `authenticated`, and wiring a second
  /// receiver onto [P2pService.onControlRequest] would answer every inbound
  /// request twice.
  bool _remoteControlInitAttempted = false;

  /// Starts the iroh host if it is not already running, registers this
  /// device's node ID with the server, and wires up a [RemoteControlReceiver]
  /// so inbound requests get answered — all only when
  /// [RemoteControlSettings.controllableEnabled] says this device should be
  /// reachable.
  ///
  /// `p2pServiceProvider.initialize()` may already be running by the time
  /// this reaches it — the unconditional call in [initState] starts it
  /// purely so this device can dial its own paired server, independent of
  /// whether it opts in to being a target — but `initialize()` is idempotent,
  /// so calling it again here is always safe and is what actually starts the
  /// host on a build where that unconditional call hasn't run yet (e.g. a
  /// fresh pairing that lands here before the microtask above resolves).
  Future<void> _initRemoteControlIfEnabled() async {
    if (_remoteControlInitAttempted) return;
    _remoteControlInitAttempted = true;

    try {
      final settings = await ref.read(remoteControlSettingsProvider.future);
      if (!await settings.controllableEnabled()) {
        debugPrint('[MyApp] Remote control opted out, not advertising');
        return;
      }

      final p2pService = ref.read(p2pServiceProvider);
      await p2pService.initialize();

      final nodeId = p2pService.nodeId;
      if (nodeId == null) {
        debugPrint(
            '[MyApp] Remote control: no node ID after initialize, skipping');
        return;
      }

      final client = await ref.read(asyncGraphqlClientProvider.future);
      final registered = await NodeRegistration(
        client: client,
        nodeId: () async => p2pService.nodeId,
      ).register();
      debugPrint('[MyApp] Remote control node registration: $registered');

      final targetController = ref.read(remoteTargetControllerProvider);
      final receiver = RemoteControlReceiver(
        roster: RemoteRoster(client: client),
        targetName: await DeviceInfoService().getDeviceName(),
        snapshotSource: targetController.snapshot,
        onIntent: targetController.submit,
        respond: p2pService.respondToControl,
      );

      _controlRequestSubscription = p2pService.onControlRequest.listen(
        (request) => unawaited(
          handleControlRequest(
            request: request,
            controllableEnabled: settings.controllableEnabled,
            respond: p2pService.respondToControl,
            handle: receiver.handle,
          ),
        ),
      );
    } catch (e) {
      // Matches `_restoreCastSession`'s catch: a startup gate that a device
      // with no reachable server, no auth, or (in tests) no initialized Hive
      // simply skips, same as opting out.
      debugPrint('[MyApp] Failed to start remote control: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _remoteIntentsSubscription?.cancel();
    _controlRequestSubscription?.cancel();
    super.dispose();
  }

  /// The only intent `RemoteTargetController` ever puts on [Stream]
  /// `intents` is `LoadContentIntent` — everything else goes straight to a
  /// mounted player, if any — but the match is written out rather than
  /// assumed, since a bare cast would silently misbehave if that ever
  /// changed.
  void _handleRemoteIntent(RemoteControlIntent intent) {
    if (intent is! LoadContentIntent) return;

    final context = rootNavigatorKey.currentContext;
    if (context == null) {
      debugPrint(
          '[MyApp] Remote LoadContent arrived before the router mounted');
      return;
    }

    unawaited(_pushLoadContent(context, intent));
  }

  /// Resolves [intent] to a playable file and pushes the player already
  /// playing it, falling back to the detail screen — the same "no file
  /// chosen yet" fallback every other entry point in this app takes (see
  /// `home_screen.dart`'s `_handlePlay`) — when nothing resolves.
  ///
  /// `router` and `screenWidth` are read from [context] before the only
  /// `await` in this method, never after: this device could navigate away
  /// or tear down while [pushLoadContentDestination] runs, and neither
  /// `context` nor anything derived from it would be safe to touch once
  /// that has happened. The whole body is wrapped in `try`/`catch` on top of
  /// [resolveLoadContentRoute]'s own — this runs off an inbound network
  /// command with no caller able to catch an escaping exception, so nothing
  /// here may ever throw, not even a `push` on a torn-down router.
  Future<void> _pushLoadContent(
    BuildContext context,
    LoadContentIntent intent,
  ) async {
    try {
      final router = GoRouter.of(context);
      final screenWidth = MediaQuery.sizeOf(context).width;

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
        push: (path) {
          if (!mounted) return;
          router.push(path);
        },
      );
    } catch (error, stackTrace) {
      debugPrint('[MyApp] Remote LoadContent handling failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (applyAppLifecycleState(_resumeGate, state, DateTime.now())) {
      // Live screens refetch now; dormant ones become cold for their next
      // mount. Fire-and-forget: a lifecycle callback cannot await, so any
      // failure is caught here rather than becoming an unhandled rejection.
      unawaited(_invalidateOnResume());
    }
  }

  Future<void> _invalidateOnResume() async {
    try {
      await ref.read(invalidatorProvider).invalidateAll();
    } catch (e) {
      debugPrint('[MyApp] Resume invalidation failed: $e');
    }

    // iOS suspends the app, which kills the download loops while their database
    // rows still read as active. Coming back to the foreground is the moment to
    // pick those up.
    if (!isDownloadSupported) return;
    try {
      final downloads = await ref.read(downloadManagerProvider.future);
      await downloads.recoverStuckDownloads();
    } catch (e) {
      debugPrint('[MyApp] Download recovery on resume failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);

    debugPrint('[MyApp] authState=$authState');

    // Show loading screen while auth state is initializing
    if (authState.isLoading) {
      debugPrint('[MyApp] Showing loading screen');
      return MaterialApp(
        title: 'Mydia Player',
        debugShowCheckedModeBanner: false,
        scrollBehavior: const AppScrollBehavior(),
        theme: AppTheme.darkTheme,
        home: const Scaffold(
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Loading...', style: TextStyle(color: Colors.white)),
              ],
            ),
          ),
        ),
      );
    }

    // Show error state
    if (authState.hasError) {
      debugPrint('[MyApp] Auth error: ${authState.error}');
      return MaterialApp(
        title: 'Mydia Player',
        debugShowCheckedModeBanner: false,
        scrollBehavior: const AppScrollBehavior(),
        theme: AppTheme.darkTheme,
        home: Scaffold(
          body: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.error_outline, color: Colors.red, size: 48),
                const SizedBox(height: 16),
                Text('Error: ${authState.error}',
                    style: const TextStyle(color: Colors.white)),
              ],
            ),
          ),
        ),
      );
    }

    debugPrint('[MyApp] Auth ready, showing router');

    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Mydia Player',
      debugShowCheckedModeBanner: false,
      scrollBehavior: const AppScrollBehavior(),
      theme: AppTheme.darkTheme,
      routerConfig: router,
      // Float the cast mini controller above every route. `CastBarLayer`
      // documents what mounting it out here costs the bar.
      //
      // `WindowChromeInset` wraps it rather than the reverse: the cast bar is
      // itself a route-level overlay, so it has to sit inside the reserved
      // window chrome like everything else.
      builder: (context, child) => WindowChromeInset(
        child: CastBarLayer(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}
