import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'app.dart';
import 'core/auth/auth_storage.dart';
import 'core/auth/device_info_service.dart';
import 'core/connection/connection_provider.dart';
import 'core/crash_reporting/crash_app_context.dart';
import 'core/downloads/download_service.dart';
import 'core/crash_reporting/crash_report.dart';
import 'core/crash_reporting/crash_reporter.dart';
import 'core/crash_reporting/crash_reporter_provider.dart';
import 'package:flutter/services.dart';

import 'core/diagnostics/diagnostics_provider.dart';
import 'core/diagnostics/diagnostics_settings.dart';
import 'core/graphql/watch/fetch_log.dart';
import 'core/logging/log_platform.dart';
import 'core/logging/log_sink.dart';
import 'core/logging/log_store.dart';
import 'core/logging/log_uploader.dart';
import 'core/player/input_capabilities.dart';
import 'core/navigation/sidebar_layout_providers.dart';
import 'core/relay/relay_api_client.dart' show metadataRelayBaseUrl;
import 'core/storage/app_hive.dart';
import 'core/window/desktop_window.dart';
import 'core/startup/startup_error_app.dart';
import 'core/startup/startup_gate.dart';
import 'core/startup/startup_init.dart';
import 'core/startup/startup_timeline.dart';

import 'package:player/native/frb_generated.dart';

/// Whether this web build ships the p2p wasm module under `web/pkg/`.
///
/// Only `tool/build_web.sh` produces that module, and only the public player
/// at web.mydia.dev is built through it. The bundle a Mydia instance serves at
/// `/player` is same-origin with its own server and talks to it over plain
/// HTTP, so it has never carried the module and does not need to.
///
/// This has to be decided at build time rather than probed at runtime.
/// flutter_rust_bridge's web loader appends a `<script>` for the module and
/// awaits its `load` event with no error path, so a module that is not there
/// does not throw. It hangs, and `_startApp` would never reach `runApp`.
const kWebP2pEnabled = bool.fromEnvironment('MYDIA_WEB_P2P');

/// Ceiling on `RustLib.init()`, so `_startApp` cannot stall forever.
///
/// [kWebP2pEnabled] keeps a build that never had the module from reaching the
/// loader at all. This covers the other half: a build that expects the module
/// and does not find it at runtime, through deploy skew, a wrong base href, a
/// partial upload or a bad cache. The loader has no error path, so a 404 there
/// is an await that never returns, and `_startApp`'s promise to call `runApp`
/// exactly once on every path would be broken on precisely the public build
/// this exists to enable.
///
/// A minute is a ceiling, not a latency budget. The failure it guards resolves
/// in milliseconds, so nothing correct is ever waiting on it. What has to fit
/// underneath is a cold fetch and instantiation of a ~5 MB module on a poor
/// connection, and the bundle's own `main.dart.js` is comparable in size and
/// has already loaded by the time this runs, so the connection has proved
/// itself. Timing out lands in the same catch as any other init failure, and
/// on a build that ships the module that is fatal: see `_startApp`.
const _rustInitTimeout = Duration(seconds: 60);

void main() async {
  // Starts the cold-start timeline's stopwatch. First statement, so every
  // later mark is relative to the true beginning of startup.
  StartupTimeline.app.mark('main');

  // Records every debugPrint for the local log files and, when the user
  // shares them, the relay. First, so nothing logged at startup is missed.
  // See core/logging/log_sink.dart.
  final logSink = kIsWeb ? null : LogSink.install();

  // Presents and logs every Flutter framework error, as this spot always has,
  // and reports it to the relay once the user opts in. See
  // core/crash_reporting/crash_reporter.dart.
  final crashReporter = CrashReporter.production()..install();

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

      await _startApp(crashReporter, logSink);
    },
    (error, stack) {
      // `_startApp` guarantees `runApp` has already run by the time control
      // reaches here, falling back to a startup-error screen along the way
      // if a step failed fatally. This handler only logs and reports
      // whatever slips through afterwards (e.g. an error from deep inside a
      // running widget tree). It must never again be the sole handler of a
      // fatal startup failure, silently leaving the window black.
      debugPrint('Caught error: $error');
      debugPrint('Stack trace: $stack');
      logSink?.recordError(error, stack);
      unawaited(crashReporter.report(error, stack, capture: CrashCapture.zone));
    },
  );
}

/// Hands `runApp` a [StartupGate] immediately, so the first frame is a
/// splash rather than a black window, and runs the rest of startup behind it.
///
/// Invariant: `runApp` is called exactly once, here. Every failure path the
/// old sequential version reached through its own `runApp` call is now a
/// child the gate swaps in. See `core/startup/startup_init.dart` for which
/// steps run concurrently and why.
Future<void> _startApp(CrashReporter crashReporter, LogSink? logSink) async {
  final timeline = StartupTimeline.app;

  // Point the log sink at its files first. Not awaited: the sink buffers its
  // first records in memory until the store attaches, so opening the files
  // can overlap the rest of startup. Never throws; see _attachLogStore.
  final logStoreFuture = _attachLogStore(logSink);
  LogStore? logStore;

  // Initialize media_kit for video playback. Best-effort and synchronous.
  try {
    MediaKit.ensureInitialized();
  } catch (e, st) {
    debugPrint('[MediaKit] Failed to initialize: $e');
    debugPrint('Stack trace: $st');
  }

  // Stays ahead of `runApp`: it restores window geometry, which has to be in
  // place before the first frame paints. A no-op off desktop, and it never
  // throws. `initAppHive` is memoized, so its Hive init is shared with the
  // cache step below.
  await initDesktopWindow();
  timeline.mark('desktop_window');

  final startup = runStartup(
    StartupSteps(
      rustInit: (!kIsWeb || kWebP2pEnabled)
          ? () => RustLib.init().timeout(_rustInitTimeout)
          : null,
      inputCapabilities: InputCapabilities.initialize,
      hiveCache: () async {
        // `initAppHive` plus an explicit `HiveStore.open` rather than
        // graphql_flutter's `initHiveForFlutter`, which hard-wires the base
        // path to the user's Documents folder. See `core/storage/app_hive.dart`.
        await initAppHive();
        await HiveStore.open();
      },
      fetchLog: HiveFetchLog.open,
      downloadDb:
          isDownloadSupported ? () => getDownloadDatabase().initialize() : null,
      sidebarLayoutStore: () async {
        final container = ProviderContainer();
        try {
          return await container.read(sidebarLayoutStoreAsyncProvider.future);
        } finally {
          container.dispose();
        }
      },
      connection: () => loadStoredConnectionState(getAuthStorage()),
    ),
    timeline: timeline,
  ).then((outcome) async {
    logStore = await logStoreFuture;
    return outcome;
  });

  runApp(
    StartupGate(
      startup: startup,
      buildApp: (ready) => ProviderScope(
        overrides: [
          crashReporterProvider.overrideWithValue(crashReporter),
          fetchLogProvider.overrideWithValue(ready.fetchLog),
          sidebarLayoutStoreProvider
              .overrideWithValue(ready.sidebarLayoutStore),
          initialConnectionStateProvider
              .overrideWithValue(ready.initialConnection),
          logUploaderProvider.overrideWithValue(
            _buildLogUploader(logSink, logStore),
          ),
        ],
        child: const MyApp(),
      ),
      buildFailure: (failure) => switch (failure) {
        StartupRustFailed(:final error, :final stackTrace) =>
          StartupErrorApp.generic(
            error,
            report: crashReporter.reportStartupFailure(error, stackTrace),
          ),
        StartupAlreadyRunning(:final error) =>
          StartupErrorApp.alreadyRunning(error),
        StartupReady() => throw StateError('unreachable'),
      },
    ),
  );

  WidgetsBinding.instance.addPostFrameCallback((_) {
    timeline.mark('first_frame');
  });
}

/// Opens the on-disk log and points [sink] at it.
///
/// Never throws: logs are diagnostics, never a reason to fail startup. Null
/// when there is no sink (web) or the store could not be opened, in which case
/// the sink keeps its first [LogSink.maxPending] records in memory and drops
/// the rest.
Future<LogStore?> _attachLogStore(LogSink? sink) async {
  if (sink == null) return null;
  try {
    final store = await openLogStore(
      sessionId: sink.sessionId,
      onDisabled: (reason) =>
          sink.consoleOnly('[LogStore] Disk logging stopped: $reason'),
    );
    if (store == null) return null;
    sink.attach(store);
    unawaited(_recordSession(sink));
    return store;
  } catch (e) {
    debugPrint('[LogSink] Could not open the log store: $e');
    return null;
  }
}

/// The `Session` record every launch starts with.
Future<void> _recordSession(LogSink sink) async {
  try {
    final context = await loadCrashAppContext();
    final deviceName = await DeviceInfoService().getDeviceName();
    sink.recordSession({
      'version': context.version,
      'build': context.buildNumber,
      'platform': context.platform,
      'os': context.osVersion,
      'device': deviceName,
    });
  } catch (e) {
    debugPrint('[LogSink] Could not describe the session: $e');
  }
}

/// The uploader behind the Diagnostics choice, or null without a log store.
LogUploader? _buildLogUploader(LogSink? sink, LogStore? store) {
  if (sink == null || store == null) return null;
  final settings = DiagnosticsSettings();
  LogUploadMeta? meta;
  return LogUploader(
    client: http.Client(),
    endpoint: Uri.parse('$metadataRelayBaseUrl/player-logs'),
    store: store,
    sessionId: sink.sessionId,
    compress: gzipBytes,
    loadMeta: () async => meta ??= await _describeInstall(settings),
  );
}

Future<LogUploadMeta> _describeInstall(DiagnosticsSettings settings) async {
  final context = await loadCrashAppContext();
  return LogUploadMeta(
    deviceId: await settings.deviceId(),
    deviceName: await DeviceInfoService().getDeviceName(),
    platform: context.platform,
    osVersion: context.osVersion,
    appVersion: context.version,
    build: context.buildNumber,
  );
}
