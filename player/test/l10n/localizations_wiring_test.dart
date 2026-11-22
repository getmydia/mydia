import 'package:material_ui/material_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoLocalizations, DefaultCupertinoLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';
import 'package:player/l10n/locale_names.dart';

void main() {
  Widget app(Locale locale) => MaterialApp(
    locale: locale,
    localizationsDelegates: appLocalizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    localeListResolutionCallback: resolveAppLocale,
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

  // material_ui and cupertino_ui declare their own MaterialLocalizations and
  // CupertinoLocalizations, so flutter_localizations' delegates (which the
  // generated AppLocalizations.localizationsDelegates still lists) translate
  // nothing the migrated widgets read. A non-English locale must get both
  // from the new packages, aliased languages included.
  for (final locale in const [Locale('es'), Locale('cnr')]) {
    testWidgets('$locale gets translated Material and Cupertino strings', (
      tester,
    ) async {
      late BuildContext captured;
      await tester.pumpWidget(
        MaterialApp(
          locale: locale,
          localizationsDelegates: appLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          localeListResolutionCallback: resolveAppLocale,
          home: Builder(
            builder: (context) {
              captured = context;
              return const SizedBox();
            },
          ),
        ),
      );
      expect(
        MaterialLocalizations.of(captured),
        isNot(isA<DefaultMaterialLocalizations>()),
      );
      expect(
        Localizations.of<CupertinoLocalizations>(
          captured,
          CupertinoLocalizations,
        ),
        isNot(anyOf(isNull, isA<DefaultCupertinoLocalizations>())),
      );
    });
  }

  test('every supported locale has a display name', () {
    for (final l in AppLocalizations.supportedLocales) {
      expect(localeDisplayName(l), isNot(l.toLanguageTag()), reason: '$l');
    }
  });
}
