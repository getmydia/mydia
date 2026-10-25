import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/compatibility/compatibility_verdict.dart';
import 'package:player/core/sources/mydia/mydia_credentials.dart';
import 'package:player/core/sources/mydia/mydia_secrets.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_records.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/settings/settings_nav.dart';
import 'package:player/presentation/screens/sources/manage_sources_screen.dart';
import 'package:player/presentation/screens/sources/mydia_instance_screen.dart';

import '../../../core/sources/mydia/mydia_account_harness.dart'
    show mydiaRecord;
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';
import '../../../test_utils/toast_harness.dart';

class _RecordingNav implements SettingsNav {
  final calls = <String>[];
  @override
  void openInstance(SourceId id) => calls.add('instance ${id.value}');
  @override
  void openDiagnostics() => calls.add('diagnostics');
  @override
  void instanceRemoved() => calls.add('removed');
  @override
  void addServer() => calls.add('add');
  @override
  void reauth(SourceKind kind, String accountId) =>
      calls.add('reauth ${kind.name} $accountId');
  @override
  void switchedTo(SourceId id) => calls.add('switched ${id.value}');
}

void main() {
  final recordA = mydiaRecord('a', addedAtMs: 0);
  final idA = mydiaSourceIdOf(recordA);

  /// The router has only `/`, so a body that reached for it instead of the
  /// scope would throw "no routes for location".
  Future<void> pumpBody(
      WidgetTester tester, _RecordingNav nav, Widget body) async {
    final store = InMemorySourceStore();
    final secrets = SourceSecrets(MockAuthStorage());
    await store.putAccount(recordA);
    await writeMydiaCredentials(
        secrets,
        recordA.account,
        MydiaCredentials(
          instanceId: recordA.servers.single.id,
          accessToken: 'tok',
          serverUrl: 'https://a.example.test',
        ));
    await tester.binding.setSurfaceSize(const Size(900, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider.overrideWithValue(secrets),
        mediaSourceProvider.overrideWith((ref, id) => null),
        serverCompatibilityProvider.overrideWith((ref, id) async =>
            const ServerCompatibility(
                info: null, verdict: CompatibilityVerdict.unknown)),
      ],
      child: MaterialApp.router(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: toastLayerBuilder,
        routerConfig: GoRouter(routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => SettingsNavScope(
              nav: nav,
              child: Scaffold(body: body),
            ),
          ),
        ]),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the servers body asks the nav for every destination',
      (tester) async {
    final nav = _RecordingNav();
    await pumpBody(tester, nav, const ManageSourcesBody());

    await tester.tap(find.byKey(const Key('manage-add')));
    await tester.tap(find.byKey(Key('manage-settings-${recordA.account.id}')));
    await tester.tap(find.byKey(Key('manage-reauth-${recordA.account.id}')));
    await tester.pump();

    expect(nav.calls, [
      'add',
      'instance ${idA.value}',
      'reauth mydia ${recordA.account.id}',
    ]);
  });

  testWidgets('the instance body tells the nav when it removed the server',
      (tester) async {
    final nav = _RecordingNav();
    await pumpBody(tester, nav, MydiaInstanceBody(sourceId: idA));

    await tester.ensureVisible(find.byKey(const Key('mydia-instance-remove')));
    await tester.tap(find.byKey(const Key('mydia-instance-remove')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('manage-remove-confirm')));
    await tester.pumpAndSettle();

    expect(nav.calls, ['removed']);
  });
}
