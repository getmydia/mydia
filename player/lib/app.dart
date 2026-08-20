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
import 'core/remote/remote_control_intent.dart';
import 'core/remote/remote_target_controller.dart';
import 'core/router/navigator_keys.dart';
import 'core/scroll/app_scroll_behavior.dart';
import 'presentation/widgets/cast_mini_controller.dart';
import 'package:player/core/p2p/p2p_service.dart';

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
    ref.listenManual<AsyncValue<AuthStatus>>(
      authStateProvider,
      (previous, next) {
        if (next.value != AuthStatus.authenticated) return;
        _restoreCastSession();
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _remoteIntentsSubscription?.cancel();
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

    // The player route needs a resolved `fileId`, which nothing in this
    // intent carries — a remote controller knows what title to play, not
    // which encoded version this device should fetch. Route to the detail
    // screen instead, the same fallback every other "no file chosen yet"
    // entry point in this app takes (see `continue_watching_actions.dart`'s
    // `_handlePlay`); the viewer picks a version from there. Autoplay,
    // `startAt` and the requested audio/subtitle tracks are not applied by
    // this navigation — carrying them through to a running player is the
    // end-to-end task's job, not this one's.
    final path = intent.episodeId != null
        ? '/episode/${intent.episodeId}'
        : '/movie/${intent.mediaItemId}';
    GoRouter.of(context).push(path);
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
