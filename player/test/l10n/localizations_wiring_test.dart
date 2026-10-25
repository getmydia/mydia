import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/l10n/locale_names.dart';

void main() {
  Widget app(Locale locale) => MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: (context) => Text(context.l10n.appLoading)),
      );

  testWidgets('English is the template', (tester) async {
    await tester.pumpWidget(app(const Locale('en')));
    expect(find.text('Loading...'), findsOneWidget);
  });

  testWidgets('Spanish resolves', (tester) async {
    await tester.pumpWidget(app(const Locale('es')));
    expect(find.text('Cargando...'), findsOneWidget);
  });

  testWidgets('an unsupported locale falls back to English', (tester) async {
    await tester.pumpWidget(app(const Locale('xx')));
    expect(find.text('Loading...'), findsOneWidget);
  });

  test('every supported locale has a display name', () {
    for (final l in AppLocalizations.supportedLocales) {
      expect(localeDisplayName(l), isNot(l.toLanguageTag()), reason: '$l');
    }
  });
}
