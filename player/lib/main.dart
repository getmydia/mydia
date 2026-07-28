import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'app.dart';
import 'core/downloads/download_service.dart';
import 'core/graphql/watch/fetch_log.dart';

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

      // Initialize Rust Bridge (native platforms only - not available on web)
      // This MUST complete before any P2P/Libp2p code runs
      if (!kIsWeb) {
        try {
          await RustLib.init();
          debugPrint('[RustLib] Rust bridge initialized successfully');
        } catch (e) {
          debugPrint('[RustLib] Failed to initialize Rust bridge: $e');
          // Re-throw to prevent app from starting with broken P2P
          rethrow;
        }
      } else {
        debugPrint(
            '[RustLib] Skipping Rust bridge initialization on web platform');
      }

      // Initialize media_kit for video playback
      MediaKit.ensureInitialized();

      // TODO: Chromecast support temporarily disabled due to API incompatibility
      // with flutter_chrome_cast package. See backlog task for fix.
      // await _initializeCastSdk();

      // Initialize GraphQL Hive cache for offline support
      await initHiveForFlutter();

      // Fetch log: when each query last reached the network. A missing entry
      // is treated as infinitely stale, so an install upgrading from a build
      // without this box performs a real network fetch on first launch.
      final fetchLog = await HiveFetchLog.open();

      // Initialize download database (only on native platforms)
      if (isDownloadSupported) {
        final downloadDb = getDownloadDatabase();
        await downloadDb.initialize();
      }

      runApp(
        ProviderScope(
          overrides: [fetchLogProvider.overrideWithValue(fetchLog)],
          child: const MyApp(),
        ),
      );
    },
    (error, stack) {
      debugPrint('Caught error: $error');
      debugPrint('Stack trace: $stack');
    },
  );
}
