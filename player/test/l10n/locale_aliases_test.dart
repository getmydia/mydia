import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';

void main() {
  test('every shipped language has Flutter localizations or an alias', () {
    final missing = [
      for (final l in AppLocalizations.supportedLocales)
        if (!GlobalMaterialLocalizations.delegate.isSupported(l) &&
            !formattingAliases.containsKey(l.languageCode))
          l.toString(),
    ];
    expect(missing, isEmpty, reason: 'add the language to formattingAliases');
  });

  test('an aliased language formats with its alias', () {
    final l10n = appLocalizationsFor(const Locale('cnr'));
    expect(l10n.localeName, 'sr_Latn');
    // Plurals and number placeholders go through intl with localeName.
    expect(() => l10n.backupRestoreSummary(1, 22, 5), returnsNormally);
  });

  testWidgets('Montenegrin renders Material widgets and dates', (tester) async {
    late BuildContext captured;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('cnr'),
        localizationsDelegates: appLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            captured = context;
            return const Scaffold(body: BackButton());
          },
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(MaterialLocalizations.of(captured), isNotNull);
    final l10n = captured.l10n;
    expect(l10n.appLoading, 'Učitavam...');
    expect(l10n.monthName(DateTime(2026, 3, 2)), isNotEmpty);
  });
}
