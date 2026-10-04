import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/lock/device_auth.dart';
import 'package:player/core/sources/lock/pin_store.dart';
import 'package:player/core/sources/lock/source_lock_controller.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/screens/sources/unlock_screen.dart';

import '../../../core/sources/store/source_json_test.dart' show plexRecord;
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/toast_harness.dart';

class _Auth implements DeviceAuth {
  _Auth(this.result);
  final DeviceAuthResult result;
  int calls = 0;
  @override
  Future<bool> available() async => result != DeviceAuthResult.unavailable;
  @override
  Future<DeviceAuthResult> authenticate() async {
    calls++;
    return result;
  }
}

class _Unauthenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.unauthenticated);
}

Future<ProviderContainer> _pump(
  WidgetTester tester,
  DeviceAuth auth,
  PinStore pins, {
  List<Override> overrides = const [],
}) async {
  final router = GoRouter(initialLocation: '/unlock?next=%2Fdone', routes: [
    GoRoute(path: '/', builder: (_, __) => const Text('home')),
    GoRoute(path: '/done', builder: (_, __) => const Text('done')),
    GoRoute(
      path: '/unlock',
      builder: (_, s) => UnlockScreen(next: s.uri.queryParameters['next']),
    ),
  ]);
  final container = ProviderContainer(overrides: [
    deviceAuthProvider.overrideWithValue(auth),
    pinStoreProvider.overrideWithValue(pins),
    ...overrides,
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp.router(builder: toastLayerBuilder, routerConfig: router),
  ));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _enter(WidgetTester tester, String pin) async {
  for (final d in pin.split('')) {
    await tester.tap(find.byKey(Key('pin-pad-$d')));
  }
  await tester.tap(find.byKey(const Key('pin-pad-ok')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('device auth on open, then continues to next', (tester) async {
    final auth = _Auth(DeviceAuthResult.success);
    final c = await _pump(
        tester, auth, PinStore(MockAuthStorage(), iterations: 1000));
    expect(auth.calls, 1);
    expect(find.text('done'), findsOneWidget);
    expect(c.read(sourceLockProvider), isTrue);
  });

  testWidgets('no device auth: the PIN pad unlocks', (tester) async {
    final pins = PinStore(MockAuthStorage(), iterations: 1000);
    await pins.setPin('4821');
    await _pump(tester, _Auth(DeviceAuthResult.unavailable), pins);
    expect(find.byKey(const Key('pin-pad')), findsOneWidget);
    await _enter(tester, '0000');
    expect(find.byKey(const Key('pin-pad-error')), findsOneWidget);
    await _enter(tester, '4821');
    expect(find.text('done'), findsOneWidget);
  });

  testWidgets('cancelled device auth offers retry and PIN', (tester) async {
    await _pump(tester, _Auth(DeviceAuthResult.cancelled),
        PinStore(MockAuthStorage(), iterations: 1000));
    expect(find.byKey(const Key('unlock-retry-device')), findsOneWidget);
    await tester.tap(find.byKey(const Key('unlock-use-pin')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('pin-pad')), findsOneWidget);
  });

  testWidgets('cancel goes home', (tester) async {
    await _pump(tester, _Auth(DeviceAuthResult.cancelled),
        PinStore(MockAuthStorage(), iterations: 1000));
    await tester.tap(find.byKey(const Key('unlock-cancel')));
    await tester.pumpAndSettle();
    expect(find.text('home'), findsOneWidget);
  });

  testWidgets('Forgot PIN removes locked accounts and the PIN', (tester) async {
    final storage = MockAuthStorage();
    final store = InMemorySourceStore();
    final pins = PinStore(storage, iterations: 1000);
    await pins.setPin('4821');
    final record = plexRecord();
    await store.putAccount(record
        .copyWith(serverLocks: {record.servers.single.id: SourceLock.locked}));
    final c = await _pump(
      tester,
      _Auth(DeviceAuthResult.unavailable),
      pins,
      overrides: [
        authStateProvider.overrideWith(_Unauthenticated.new),
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(SourceSecrets(storage)),
      ],
    );
    await c.read(sourceRecordsProvider.future);

    await tester.tap(find.byKey(const Key('unlock-forgot-pin')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('unlock-forgot-confirm')));
    await tester.pumpAndSettle();

    expect((await store.load()).accounts, isEmpty);
    expect(await pins.hasPin(), isFalse);
    expect(find.text('home'), findsOneWidget);
  });
}
