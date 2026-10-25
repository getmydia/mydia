import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/l10n/l10n.dart';

void main() {
  const supported = [
    Locale('en'),
    Locale('es'),
    Locale('pt'),
    Locale('pt', 'BR'),
  ];

  Locale resolve(List<Locale> device) => resolveLocaleList(device, supported);

  group('resolveLocaleList', () {
    test('an exact match wins', () {
      expect(resolve([const Locale('pt', 'BR')]), const Locale('pt', 'BR'));
      expect(resolve([const Locale('es')]), const Locale('es'));
    });

    test('a region the player lacks falls to the language', () {
      expect(resolve([const Locale('es', 'MX')]), const Locale('es'));
      expect(resolve([const Locale('en', 'GB')]), const Locale('en'));
    });

    test('Portuguese resolves to the regional variant, never the stub', () {
      expect(resolve([const Locale('pt')]), const Locale('pt', 'BR'));
      expect(resolve([const Locale('pt', 'PT')]), const Locale('pt', 'BR'));
    });

    test('an unshipped language shows English', () {
      expect(resolve([const Locale('de')]), const Locale('en'));
      expect(resolve(const []), const Locale('en'));
    });

    test('keeps the order of the device list, as Flutter does', () {
      expect(
        resolve([const Locale('es', 'MX'), const Locale('en')]),
        const Locale('es'),
      );
      expect(
        resolve([const Locale('pt', 'PT'), const Locale('en')]),
        const Locale('pt', 'BR'),
      );
      expect(
        resolve([const Locale('de'), const Locale('pt', 'PT')]),
        const Locale('pt', 'BR'),
      );
      expect(resolve([const Locale('de'), const Locale('es')]),
          const Locale('es'));
      expect(resolve([const Locale('en', 'GB')]), const Locale('en'));
      expect(resolveLocaleList(null, supported), const Locale('en'));
    });

    test('matches Flutter for every language without a stub', () {
      const withoutStub = [Locale('en'), Locale('es'), Locale('pt', 'BR')];
      const lists = [
        [Locale('es', 'MX'), Locale('en')],
        [Locale('en', 'US'), Locale('es')],
        [Locale('de'), Locale('es', 'AR'), Locale('en')],
        [Locale('es'), Locale('es', 'MX')],
        [Locale('fr')],
      ];
      for (final l in lists) {
        expect(
          resolveLocaleList(l, supported),
          basicLocaleListResolution(l, withoutStub),
          reason: '$l',
        );
      }
    });

    test('a language with no regional variant keeps its stub', () {
      expect(
        resolveLocaleList(
          [const Locale('fr')],
          const [Locale('en'), Locale('fr')],
          stubs: const {},
        ),
        const Locale('fr'),
      );
    });
  });

  test('the stub is hidden from the picker', () {
    expect(isStubLocale(const Locale('pt')), isTrue);
    expect(isStubLocale(const Locale('pt', 'BR')), isFalse);
    expect(isStubLocale(const Locale('es')), isFalse);
    expect(pickableLocales, isNot(contains(const Locale('pt'))));
    expect(pickableLocales, contains(const Locale('pt', 'BR')));
  });

  test('the generated app resolves Portuguese to pt_BR', () {
    expect(
      resolveLocaleList(
        const [Locale('pt', 'PT')],
        AppLocalizations.supportedLocales,
      ),
      const Locale('pt', 'BR'),
    );
  });

  group('stub registry', () {
    final dir = Directory('lib/l10n');
    Map<String, dynamic> load(File f) =>
        jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
    bool hasMessages(Map<String, dynamic> arb) =>
        arb.keys.any((k) => !k.startsWith('@'));

    test('every listed stub ARB holds only @@locale', () {
      for (final code in stubLanguageCodes) {
        final arb = load(File('lib/l10n/app_$code.arb'));
        expect(arb.keys.toList(), ['@@locale'], reason: 'app_$code.arb');
        expect(arb['@@locale'], code);
      }
    });

    test('every message-free base ARB is listed as a stub', () {
      final unlisted = <String>[];
      for (final f in dir.listSync().whereType<File>()) {
        final m = RegExp(r'app_([a-z]+)\.arb$').firstMatch(f.path);
        if (m == null) continue;
        if (!hasMessages(load(f)) && !stubLanguageCodes.contains(m.group(1))) {
          unlisted.add(f.path);
        }
      }
      expect(unlisted, isEmpty,
          reason: 'add the language to stubLanguageCodes');
    });
  });
}
