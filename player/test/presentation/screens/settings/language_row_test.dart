import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/settings/locale_setting.dart';
import 'package:player/core/settings/settings_providers.dart';
import 'package:player/core/settings/settings_service.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/theme_providers.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/presentation/screens/settings/widgets/language_row.dart';

import '../../../test_utils/mock_auth_storage.dart';

class _Host extends ConsumerWidget {
  const _Host();
  @override
  Widget build(BuildContext context, WidgetRef ref) => MaterialApp(
        theme: AppTheme.build(ref.watch(paletteProvider), liquid: false),
        locale: ref.watch(localeSettingProvider),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: LanguageSettingsRow()),
      );
}

Widget _host(MockAuthStorage storage) => ProviderScope(
      overrides: [
        coreSettingsServiceProvider
            .overrideWithValue(SettingsService(storage: storage)),
      ],
      child: const _Host(),
    );

Finder _inRow(String text) => find.descendant(
      of: find.byKey(const Key('language-row')),
      matching: find.text(text),
    );

Future<void> _openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('language-row')));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('shows Language with System default when nothing is stored',
      (tester) async {
    await tester.pumpWidget(_host(MockAuthStorage()));
    await tester.pumpAndSettle();
    expect(_inRow('Language'), findsOneWidget);
    expect(_inRow('System default'), findsOneWidget);
  });

  testWidgets('the picker lists system default and each shipped language',
      (tester) async {
    await tester.pumpWidget(_host(MockAuthStorage()));
    await tester.pumpAndSettle();
    await _openPicker(tester);
    expect(find.byKey(const Key('language-option-system')), findsOneWidget);
    expect(find.byKey(const Key('language-option-en')), findsOneWidget);
    expect(find.byKey(const Key('language-option-es')), findsOneWidget);
    expect(find.text('Español'), findsOneWidget);
  });

  testWidgets('only the current language tile is marked selected',
      (tester) async {
    final storage = MockAuthStorage()..seedData({'interface_locale': 'es'});
    await tester.pumpWidget(_host(storage));
    await tester.pumpAndSettle();
    await _openPicker(tester);
    bool selected(String key) =>
        tester.widget<ListTile>(find.byKey(Key(key))).selected;
    expect(selected('language-option-es'), isTrue);
    expect(selected('language-option-en'), isFalse);
    expect(selected('language-option-system'), isFalse);
  });

  testWidgets('picking Spanish stores it and re-localizes the row',
      (tester) async {
    final storage = MockAuthStorage();
    await tester.pumpWidget(_host(storage));
    await tester.pumpAndSettle();
    await _openPicker(tester);
    await tester.tap(find.byKey(const Key('language-option-es')));
    await tester.pumpAndSettle();
    expect(_inRow('Idioma'), findsOneWidget);
    expect(storage.contents['interface_locale'], 'es');
  });

  testWidgets('choosing System default clears the stored language',
      (tester) async {
    final storage = MockAuthStorage()..seedData({'interface_locale': 'es'});
    await tester.pumpWidget(_host(storage));
    await tester.pumpAndSettle();
    expect(_inRow('Idioma'), findsOneWidget);
    await _openPicker(tester);
    await tester.tap(find.byKey(const Key('language-option-system')));
    await tester.pumpAndSettle();
    expect(_inRow('Language'), findsOneWidget);
    expect(storage.contents.containsKey('interface_locale'), isFalse);
  });

  testWidgets('dismissing the picker leaves the stored language alone',
      (tester) async {
    final storage = MockAuthStorage()..seedData({'interface_locale': 'es'});
    await tester.pumpWidget(_host(storage));
    await tester.pumpAndSettle();
    await _openPicker(tester);
    Navigator.of(tester.element(find.byKey(const Key('language-option-es'))))
        .pop();
    await tester.pumpAndSettle();
    expect(storage.contents['interface_locale'], 'es');
    expect(_inRow('Idioma'), findsOneWidget);
  });
}
