import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'core/theme/app_theme.dart';
import 'core/providers/providers.dart';
import 'core/graphql/graphql_provider.dart';
import 'core/graphql/watch/resume_gate.dart';
import 'core/graphql/watch/watcher_registry.dart';
import 'presentation/widgets/cast_mini_controller.dart';
import 'package:player/core/p2p/p2p_service.dart';

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  final ResumeGate _resumeGate = ResumeGate();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
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
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
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
      theme: AppTheme.darkTheme,
      routerConfig: router,
      builder: (context, child) {
        // Add cast mini controller overlay to all screens
        return Stack(
          children: [
            if (child != null) child,
            const Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: CastMiniController(),
            ),
          ],
        );
      },
    );
  }
}
