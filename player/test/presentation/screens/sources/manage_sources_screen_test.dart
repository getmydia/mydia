import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/sources/store/source_secrets.dart';
import 'package:player/core/sources/store/source_store.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/presentation/screens/sources/manage_sources_screen.dart';

import '../../../core/sources/store/source_json_test.dart' show plexRecord;
import '../../../test_utils/mock_auth_storage.dart';
import '../../../test_utils/no_downloads.dart';
import '../../../test_utils/toast_harness.dart';

void main() {
  testWidgets('hides a hidden server while locked and offers Show hidden',
      (tester) async {
    final store = InMemorySourceStore();
    await store.putAccount(plexRecord()
        .copyWith(serverLocks: const {'abc123': SourceLock.hidden}));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        ...noHiveOverrides,
        sourceStoreProvider.overrideWith((ref) async => store),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: toastLayerBuilder,
          home: ManageSourcesScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Attic'), findsNothing);
    expect(find.text('quill'), findsNothing);
    expect(find.byKey(const Key('show-hidden-sources')), findsOneWidget);
  });

  testWidgets('Show hidden is there with nothing hidden', (tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sourceStoreProvider.overrideWith((ref) async => InMemorySourceStore()),
        sourceSecretsProvider
            .overrideWithValue(SourceSecrets(MockAuthStorage())),
      ],
      child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          builder: toastLayerBuilder,
          home: ManageSourcesScreen()),
    ));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('show-hidden-sources')), findsOneWidget);
  });
}
