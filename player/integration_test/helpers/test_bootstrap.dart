import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/native/frb_generated.dart';

/// One-time initialization shared by every integration test file.
///
/// When test files run individually each one initializes for itself. When
/// [all_tests.dart] aggregates them into a single process they share one
/// isolate, and `RustLib.init()` throws if called twice. Awaiting this from
/// every `setUpAll` makes both arrangements work.
Future<void>? _bootstrap;

Future<void> ensureTestBootstrap() {
  return _bootstrap ??= _runBootstrap();
}

Future<void> _runBootstrap() async {
  await RustLib.init();
  MediaKit.ensureInitialized();
  await initHiveForFlutter();
}
