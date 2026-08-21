import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/app.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/test_bootstrap.dart';

/// Smoke test that the native Rust bridge and the app boot together.
///
/// This used to assert on `Result: \`Hello, Tom!\`` text rendered by the
/// flutter_rust_bridge quickstart's demo `greet()` call. `MyApp` grew into
/// the real player and stopped rendering it; the Rust `greet()` function
/// itself lives on in `rust/mydia_player_p2p/src/api/simple.rs` but that
/// module was never wired into `lib.rs`, so it isn't part of the compiled
/// crate and has no generated Dart binding to call. The assertion could
/// never pass again as written.
///
/// `ensureTestBootstrap` already proves the native bridge loads (it awaits
/// `RustLib.init()`, which throws if it doesn't), so what is left worth
/// testing here is that `MyApp` mounts cleanly on top of it. Also missing
/// until now: `MyApp` requires a `ProviderScope` ancestor (it is a
/// `ConsumerStatefulWidget`), which this test never provided, so it always
/// threw `Bad state: No ProviderScope found` during `initState`. Nothing
/// caught that until this file actually ran.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(ensureTestBootstrap);
  testWidgets('App boots with the native bridge initialized',
      (WidgetTester tester) async {
    // Registered before the mount, not called at the end of the body: a
    // failing expect below would skip a terminal call, leaving the app mounted
    // for the framework to dispose later, which is the exact teardown this
    // helper exists to make safe.
    addTearDown(() => unmountApp(tester));

    await tester.pumpWidget(const ProviderScope(child: MyApp()));
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
