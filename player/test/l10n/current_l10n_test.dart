import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';

void main() {
  tearDown(() => rememberInterfaceLocale(null));

  test('follows the language chosen in Settings', () {
    rememberInterfaceLocale(const Locale('es'));
    expect(currentAppLocalizations().navHome, 'Inicio');

    rememberInterfaceLocale(
        const Locale.fromSubtags(languageCode: 'pt', countryCode: 'BR'));
    expect(currentAppLocalizations().navHome, 'Início');
  });

  test('follows the device when nothing was chosen', () {
    rememberInterfaceLocale(null);
    // The test binding's device language is English.
    expect(currentAppLocalizations().navHome, 'Home');
  });
}
