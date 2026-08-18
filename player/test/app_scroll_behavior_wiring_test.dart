// `app.dart` builds three different MaterialApps depending on auth state. All
// three must carry AppScrollBehavior: only the router one has scrollables
// today, but a loading or error screen that grows one later must not silently
// fall back to the stock behavior.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:graphql_flutter/graphql_flutter.dart';
import 'package:player/app.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/cast/cast_session_manager.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/scroll/app_scroll_behavior.dart';

/// Auth notifier whose state the test drives directly.
class _FakeAuthNotifier extends AuthStateNotifier {
  _FakeAuthNotifier(this._initial);

  final AsyncValue<AuthStatus> _initial;

  @override
  AsyncValue<AuthStatus> build() => _initial;
}

void main() {
  Future<void> pumpApp(
    WidgetTester tester,
    AsyncValue<AuthStatus> auth,
  ) async {
    final container = ProviderContainer(overrides: [
      castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
      authStateProvider.overrideWith(() => _FakeAuthNotifier(auth)),
      asyncGraphqlClientProvider
          .overrideWith((ref) => Completer<GraphQLClient>().future),
      castSessionProvider.overrideWith((ref) => Stream.value(null)),
      castSessionManagerProvider
          .overrideWith((ref) => Completer<CastSessionManager>().future),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MyApp(),
    ));
    await tester.pump();
  }

  void expectBehavior(WidgetTester tester) {
    final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(app.scrollBehavior, isA<AppScrollBehavior>());
  }

  testWidgets('the loading app carries AppScrollBehavior', (tester) async {
    await pumpApp(tester, const AsyncValue.loading());
    expectBehavior(tester);
  });

  testWidgets('the error app carries AppScrollBehavior', (tester) async {
    await pumpApp(
      tester,
      AsyncValue.error(Exception('nope'), StackTrace.empty),
    );
    expectBehavior(tester);
  });

  testWidgets('the router app carries AppScrollBehavior', (tester) async {
    await pumpApp(tester, const AsyncValue.data(AuthStatus.authenticated));
    expectBehavior(tester);
  });
}
