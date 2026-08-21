import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
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

/// Replaces the app with an empty widget, after giving its startup work time
/// to settle.
///
/// Every suite that mounts `MyApp` has to unmount it before the test function
/// returns, or pending async work runs on into the next test. Doing that
/// straight away is what broke the shared-isolate run:
///
/// `MyApp`'s startup reads `asyncGraphqlClientProvider.future` (remote-control
/// init and the cast-session restore both do). Unmounting replaces the
/// `ProviderScope`, which disposes the whole `ProviderContainer`. If that
/// provider is still in its loading state at that moment, Riverpod raises
/// `StateError: The provider ... was disposed during loading state, yet no
/// value could be emitted` **synchronously** out of
/// `ElementWithFuture.dispose`, inside `StatefulElement.unmount` inside
/// `drawFrame`. Flutter reports that against whichever test happens to be
/// running, and it corrupts `TestAsyncUtils`' pump guard for the rest of the
/// isolate, so every later suite dies on "Guarded function conflict" without
/// running a line of its own body. That is how one teardown took out four
/// unrelated files.
///
/// Pumping first lets the chain reach a resolved state (data or error) so
/// disposal has something to emit. Both outcomes are fine; only *loading* at
/// dispose time throws.
///
/// This is a harness concern rather than an app bug. Production never disposes
/// the container: `ProviderScope` is mounted once and lives for the life of
/// the process. Repeated mount/unmount is something only this suite does.
///
/// [settle] is a ceiling, not a sleep — the loop stops as soon as the tree
/// stops scheduling frames.
Future<void> unmountApp(
  WidgetTester tester, {
  Duration settle = const Duration(seconds: 5),
}) async {
  final deadline = DateTime.now().add(settle);
  while (DateTime.now().isBefore(deadline)) {
    await tester.pump(const Duration(milliseconds: 100));
    if (!WidgetsBinding.instance.hasScheduledFrame) break;
  }

  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(milliseconds: 100));
}
