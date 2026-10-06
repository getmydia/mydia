import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/presentation/widgets/nav/source_picker.dart';

import '../../../core/sources/store/source_json_test.dart' show plexRecord;
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/mydia_test_source.dart';

class _Authenticated extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.authenticated);
}

Future<String> _pump(WidgetTester tester, SourceLock lock) async {
  final store = InMemorySourceStore();
  final record = plexRecord().copyWith(serverLocks: {'abc123': lock});
  await store.putAccount(testMydiaRecord());
  await store.putAccount(record);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      authStateProvider.overrideWith(_Authenticated.new),
      sourceStoreProvider.overrideWith((ref) async => store),
      sourceSecretsProvider.overrideWithValue(SourceSecrets(MockAuthStorage())),
    ],
    child: const MaterialApp(
      home: Scaffold(body: SourcePickerList(currentId: testMydiaSourceId)),
    ),
  ));
  await tester.pumpAndSettle();
  return record.sources.single.id.value;
}

void main() {
  testWidgets('a locked server shows a lock while the app is locked',
      (tester) async {
    final id = await _pump(tester, SourceLock.locked);
    expect(find.byKey(ValueKey('source-switcher-$id')), findsOneWidget);
    expect(find.byKey(ValueKey('source-switcher-lock-$id')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('source-switcher-hidden')), findsOneWidget);
  });

  testWidgets('a hidden server is left out while the app is locked',
      (tester) async {
    final id = await _pump(tester, SourceLock.hidden);
    expect(find.byKey(ValueKey('source-switcher-$id')), findsNothing);
    expect(
        find.byKey(const ValueKey('source-switcher-hidden')), findsOneWidget);
  });
}
