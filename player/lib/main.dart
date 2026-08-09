import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'app.dart';
import 'core/downloads/download_service.dart';
import 'package:flutter/services.dart';

import 'core/graphql/watch/fetch_log.dart';
import 'core/navigation/sidebar_layout_providers.dart';
import 'core/window/desktop_window.dart';
import 'core/startup/startup_error_app.dart';
import 'core/startup/startup_lock.dart';

// Only import FRB on native platforms (not web)
// ignore: unused_import
import 'package:player/native/frb_generated.dart'
    if (dart.library.js_interop) 'package:player/native/frb_stub.dart';

void main() async {
  // Add error logging for debugging
  FlutterError.onError = (details) {
    FlutterError.presentError(details);
    debugPrint('Flutter error: ${details.exception}');
    debugPrint('Stack trace: ${details.stack}');
  };

  runZonedGuarded(
    () async {
      WidgetsFlutterBinding.ensureInitialized();

      // Register the bundled Inter font's license. Deliberately out here
      // rather than in `_startApp`: `addLicense` only stores the callback,
      // and the `rootBundle` read inside it does not run until someone opens
      // the licenses page. There is no startup step to fail, so it needs
      // none of `_startApp`'s degraded-mode handling.
      LicenseRegistry.addLicense(() async* {
        final license =
            await rootBundle.loadString('assets/fonts/Inter-LICENSE.txt');
        yield LicenseEntryWithLineBreaks(<String>['Inter'], license);
      });

      await _startApp();
    },
    (error, stack) {
      // `_startApp` guarantees `runApp` has already run by the time control
      // reaches here, falling back to a startup-error screen along the way
      // if a step failed fatally. This handler only logs whatever slips
      // through afterwards (e.g. an error from deep inside a running widget
      // tree) — it must never again be the sole handler of a fatal startup
      // failure, silently leaving the window black.
      debugPrint('Caught error: $error');
      debugPrint('Stack trace: $stack');
    },
  );
}

/// Runs every startup step needed before [runApp], degrading gracefully
/// where a failure allows it and falling back to [StartupErrorApp] where it
/// doesn't.
///
/// Invariant: this function calls `runApp` exactly once, on every path.
/// Nothing after `WidgetsFlutterBinding.ensureInitialized()` is allowed to
/// throw its way out of here uncaught, because a second instance of this
/// app pointed at the same user-data directory will otherwise leave the
/// window completely black forever with no indication why (the bug this
/// function exists to fix).
Future<void> _startApp() async {
  // Initialize Rust Bridge (native platforms only - not available on web).
  // This MUST complete before any P2P/Libp2p code runs. Unlike the steps
  // below, there's no reasonable degraded mode without it, so a failure here
  // goes straight to the last-resort error screen rather than continuing.
  if (!kIsWeb) {
    try {
      await RustLib.init();
      debugPrint('[RustLib] Rust bridge initialized successfully');
    } catch (e, st) {
      debugPrint('[RustLib] Failed to initialize Rust bridge: $e');
      debugPrint('Stack trace: $st');
      runApp(StartupErrorApp.generic(e));
      return;
    }
  } else {
    debugPrint('[RustLib] Skipping Rust bridge initialization on web platform');
  }

  // Initialize media_kit for video playback. Best-effort: the rest of the
  // app (browsing, library management, etc.) works without it — only
  // playback would be affected, and that fails on its own terms later.
  try {
    MediaKit.ensureInitialized();
  } catch (e, st) {
    debugPrint('[MediaKit] Failed to initialize: $e');
    debugPrint('Stack trace: $st');
  }

  // Prepare the OS window on native desktop: restore the size, position and
  // maximized state from the last run, apply a minimum size, and enable
  // hold-anywhere dragging. Runs before `runApp` so the window is already the
  // right shape by the time the first frame paints.
  //
  // Best-effort and self-guarding: `initDesktopWindow` never throws and is a
  // no-op off desktop, so this cannot violate this function's invariant that
  // `runApp` is called exactly once on every path. It opens its own Hive box
  // rather than depending on the `initHiveForFlutter` call further down, since
  // geometry must be restored before the first frame.
  await initDesktopWindow();

  // Everything below persists to Hive boxes under the same per-user data
  // directory. A second instance of the app fails to open every one of them
  // with the same lock error, so the first failure that looks like lock
  // contention short-circuits straight to a dedicated, actionable screen
  // instead of limping through the remaining steps degraded.
  FetchLog fetchLog = InMemoryFetchLog();

  try {
    // Initialize GraphQL Hive cache for offline support. Best-effort: it's
    // an optimisation for offline support, not a requirement to run.
    await initHiveForFlutter();
  } catch (e, st) {
    debugPrint('[Hive] Failed to initialize GraphQL cache: $e');
    debugPrint('Stack trace: $st');
    if (isLockContentionError(e)) {
      runApp(StartupErrorApp.alreadyRunning(e));
      return;
    }
    // Any other cause: continue without a persistent GraphQL cache.
  }

  try {
    // Fetch log: when each query last reached the network. A missing entry
    // is treated as infinitely stale, so an install upgrading from a build
    // without this box performs a real network fetch on first launch.
    fetchLog = await HiveFetchLog.open();
  } catch (e, st) {
    debugPrint('[Hive] Failed to open fetch log: $e');
    debugPrint('Stack trace: $st');
    if (isLockContentionError(e)) {
      runApp(StartupErrorApp.alreadyRunning(e));
      return;
    }
    // Any other cause: `fetchLog` stays the in-memory fallback assigned
    // above, so every query is simply treated as stale this session.
  }

  // Initialize download database (only on native platforms).
  if (isDownloadSupported) {
    try {
      final downloadDb = getDownloadDatabase();
      await downloadDb.initialize();
    } catch (e, st) {
      debugPrint('[Downloads] Failed to initialize download database: $e');
      debugPrint('Stack trace: $st');
      if (isLockContentionError(e)) {
        runApp(StartupErrorApp.alreadyRunning(e));
        return;
      }
      // Any other cause: downloads are unavailable this session, the rest
      // of the app still works.
    }
  }

  final startupContainer = ProviderContainer();
  final sidebarLayoutStore =
      await startupContainer.read(sidebarLayoutStoreAsyncProvider.future);
  startupContainer.dispose();

  runApp(
    ProviderScope(
      overrides: [
        fetchLogProvider.overrideWithValue(fetchLog),
        sidebarLayoutStoreProvider.overrideWithValue(sidebarLayoutStore),
      ],
      child: const MyApp(),
    ),
  );
}
