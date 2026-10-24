import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Every translation must use keys the English template defines and the same
/// `{placeholders}`, so a Weblate PR cannot break a screen.
void main() {
  final dir = Directory('lib/l10n');
  Map<String, dynamic> load(File f) =>
      jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;

  final template = load(File('lib/l10n/app_en.arb'));
  final messages = {
    for (final e in template.entries)
      if (!e.key.startsWith('@')) e.key: e.value as String,
  };

  // Placeholder names, ignoring ICU plural/select keywords and branch text.
  Set<String> placeholders(String message) {
    final names = <String>{};
    for (final m in RegExp(r'\{(\w+)(?:,|\})').allMatches(message)) {
      names.add(m.group(1)!);
    }
    return names;
  }

  final translations = dir
      .listSync()
      .whereType<File>()
      .where((f) => RegExp(r'app_\w+\.arb$').hasMatch(f.path))
      .where((f) => !f.path.endsWith('app_en.arb'))
      .toList();

  test('placeholder parsing ignores plural branch keywords', () {
    expect(
      placeholders('{count, plural, one{{count} file} other{{count} files}}'),
      {'count'},
    );
    expect(placeholders('Added {title}'), {'title'});
  });

  test('every regional locale has its base language file', () {
    final names = dir
        .listSync()
        .whereType<File>()
        .map((f) => f.uri.pathSegments.last)
        .toSet();
    final missing = <String>[];
    for (final n in names) {
      final m = RegExp(r'^app_([a-z]+)_[A-Za-z0-9]+\.arb$').firstMatch(n);
      if (m != null && !names.contains('app_${m.group(1)}.arb')) {
        missing.add('app_${m.group(1)}.arb (for $n)');
      }
    }
    expect(
      missing,
      isEmpty,
      reason: 'gen_l10n fails pub get without the base file. Create each one '
          'containing {"@@locale": "<lang>"}.',
    );
  });

  test('there is at least one translation', () {
    expect(translations, isNotEmpty);
  });

  test('every English message has a description', () {
    final missing = messages.keys
        .where((k) => (template['@$k'] as Map?)?['description'] == null)
        .toList();
    expect(missing, isEmpty, reason: 'add "@key": {"description": ...}');
  });

  for (final file in translations) {
    group(file.uri.pathSegments.last, () {
      final arb = load(file);
      test('declares its locale', () {
        expect(arb['@@locale'], isA<String>());
      });
      test('uses only template keys', () {
        final unknown = arb.keys
            .where((k) => !k.startsWith('@'))
            .where((k) => !messages.containsKey(k))
            .toList();
        expect(unknown, isEmpty);
      });
      test('keeps every placeholder', () {
        final broken = <String>[];
        for (final e in arb.entries) {
          if (e.key.startsWith('@')) continue;
          final english = messages[e.key];
          if (english == null) continue;
          if (!setEquals(
              placeholders(english), placeholders(e.value as String))) {
            broken.add(e.key);
          }
        }
        expect(broken, isEmpty);
      });
    });
  }
}

bool setEquals(Set<String> a, Set<String> b) =>
    a.length == b.length && a.containsAll(b);
