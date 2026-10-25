import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/settings/widgets/subtitle_size_row.dart';

import '../../../test_utils/mock_auth_storage.dart';

Widget _host(MockAuthStorage storage) => ProviderScope(
      overrides: [
        coreSettingsServiceProvider
            .overrideWithValue(SettingsService(storage: storage)),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SubtitleSizeSettingsRow()),
      ),
    );

void main() {
  testWidgets('shows Medium by default', (tester) async {
    await tester.pumpWidget(_host(MockAuthStorage()));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byKey(const Key('subtitle-size-row')),
        matching: find.text('Medium'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('picking Large stores it and updates the row', (tester) async {
    final storage = MockAuthStorage();
    await tester.pumpWidget(_host(storage));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('subtitle-size-row')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('subtitle-size-option-large')));
    await tester.pumpAndSettle();

    expect(storage.contents['subtitle_size'], 'large');
    expect(
      find.descendant(
        of: find.byKey(const Key('subtitle-size-row')),
        matching: find.text('Large'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('dismissing the picker changes nothing', (tester) async {
    final storage = MockAuthStorage();
    await tester.pumpWidget(_host(storage));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('subtitle-size-row')));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(5, 5)); // barrier
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('subtitle-size-option-large')), findsNothing);
    expect(storage.contents.containsKey('subtitle_size'), isFalse);
  });
}
