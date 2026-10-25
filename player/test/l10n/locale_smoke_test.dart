import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/gen/app_localizations.dart';
import 'package:player/l10n/locale_names.dart';

void main() {
  test('ships pt and pt_BR', () {
    expect(
      AppLocalizations.supportedLocales,
      containsAll([const Locale('pt'), const Locale('pt', 'BR')]),
    );
  });

  test('pt_BR resolves to Portuguese text', () async {
    final pt = await AppLocalizations.delegate.load(const Locale('pt', 'BR'));
    final en = await AppLocalizations.delegate.load(const Locale('en'));
    expect(pt.settingsPlayback, isNot(en.settingsPlayback));
  });

  test('pt_BR has a native display name', () {
    expect(localeDisplayName(const Locale('pt', 'BR')), 'Português (Brasil)');
  });
}
