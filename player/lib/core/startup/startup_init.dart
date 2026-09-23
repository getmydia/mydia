import 'package:flutter/foundation.dart' show debugPrint;

import '../connection/connection_provider.dart';
import '../graphql/watch/fetch_log.dart';
import '../navigation/sidebar_layout_store.dart';
import 'startup_lock.dart';
import 'startup_timeline.dart';

/// The init work `main()` used to await one step at a time before `runApp`.
///
/// Injected so the ordering rules below can be tested without a Rust bridge,
/// Hive or a keychain.
class StartupSteps {
  const StartupSteps({
    required this.rustInit,
    required this.inputCapabilities,
    required this.hiveCache,
    required this.fetchLog,
    required this.downloadDb,
    required this.sidebarLayoutStore,
    required this.connection,
  });

  /// Null when this build has no Rust bridge to load (web without p2p).
  final Future<void> Function()? rustInit;
  final Future<void> Function() inputCapabilities;
  final Future<void> Function() hiveCache;
  final Future<FetchLog> Function() fetchLog;

  /// Null where downloads are unsupported.
  final Future<void> Function()? downloadDb;
  final Future<SidebarLayoutStore> Function() sidebarLayoutStore;
  final Future<ConnectionState?> Function() connection;
}

sealed class StartupOutcome {
  const StartupOutcome();
}

final class StartupReady extends StartupOutcome {
  const StartupReady({
    required this.fetchLog,
    required this.sidebarLayoutStore,
    required this.initialConnection,
  });

  final FetchLog fetchLog;
  final SidebarLayoutStore sidebarLayoutStore;
  final ConnectionState? initialConnection;
}

final class StartupRustFailed extends StartupOutcome {
  const StartupRustFailed(this.error, this.stackTrace);
  final Object error;
  final StackTrace stackTrace;
}

final class StartupAlreadyRunning extends StartupOutcome {
  const StartupAlreadyRunning(this.error);
  final Object error;
}

/// The `startup` future [StartupGate] was handed rejected outright, rather
/// than resolving to one of the outcomes above -- an unexpected throw from a
/// step [runStartup] does not itself guard, such as
/// [StartupSteps.inputCapabilities] or [StartupSteps.sidebarLayoutStore].
/// Without converting the rejection into an outcome, [StartupGate] would
/// have nothing to swap in and the splash would stay up forever.
final class StartupFailed extends StartupOutcome {
  const StartupFailed(this.error, this.stackTrace);
  final Object error;
  final StackTrace stackTrace;
}

/// Runs [steps] with every independent step in flight at once.
///
/// Only two orderings are real dependencies: the fetch log opens after the
/// GraphQL Hive cache (same box directory, and the original order), and the
/// sidebar store opens after both. Everything else used to wait on
/// everything before it for no reason, behind a black window.
///
/// Outcomes keep today's precedence: a failed Rust bridge is fatal and wins,
/// then lock contention (a second instance) on any Hive or download-db step,
/// then success with whatever degraded fallbacks applied.
Future<StartupOutcome> runStartup(
  StartupSteps steps, {
  required StartupTimeline timeline,
}) async {
  Object? lockError;

  Future<void> guarded(String label, Future<void> Function() body) async {
    try {
      await body();
    } catch (e, st) {
      debugPrint('[Startup] $label failed: $e');
      debugPrint('Stack trace: $st');
      if (isLockContentionError(e)) lockError ??= e;
    }
  }

  Future<(Object, StackTrace)?> rust() async {
    try {
      final init = steps.rustInit;
      if (init == null) return null;
      await init();
      debugPrint('[RustLib] Rust bridge initialized successfully');
      return null;
    } catch (e, st) {
      debugPrint('[RustLib] Failed to initialize Rust bridge: $e');
      return (e, st);
    } finally {
      timeline.mark('rust_init');
    }
  }

  FetchLog fetchLog = InMemoryFetchLog();
  Future<void> hiveGroup() async {
    await guarded('GraphQL cache', steps.hiveCache);
    await guarded('Fetch log', () async => fetchLog = await steps.fetchLog());
    timeline.mark('hive');
  }

  ConnectionState? connection;

  final rustFuture = rust();
  await Future.wait([
    rustFuture,
    steps.inputCapabilities().then((_) => timeline.mark('input_caps')),
    hiveGroup(),
    if (steps.downloadDb case final db?)
      guarded('Download database', db).then((_) => timeline.mark('download_db'))
    else
      Future<void>.sync(() => timeline.mark('download_db')),
    steps
        .connection()
        .then((value) => connection = value)
        .catchError((Object e) {
      debugPrint('[Startup] Connection state read failed: $e');
      return null;
    }).whenComplete(() => timeline.mark('connection')),
  ]);

  final rustFailure = await rustFuture;
  if (rustFailure != null) {
    return StartupRustFailed(rustFailure.$1, rustFailure.$2);
  }
  if (lockError case final error?) return StartupAlreadyRunning(error);

  final sidebar = await steps.sidebarLayoutStore();
  timeline.mark('sidebar');
  timeline.mark('init_done');

  return StartupReady(
    fetchLog: fetchLog,
    sidebarLayoutStore: sidebar,
    initialConnection: connection,
  );
}
