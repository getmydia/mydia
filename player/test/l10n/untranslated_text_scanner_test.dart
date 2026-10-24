import 'package:flutter_test/flutter_test.dart';

import 'untranslated_text_scanner.dart';

List<String> scan(String body) => findUntranslated(
      "import 'package:flutter/material.dart';\n$body",
      path: 'x.dart',
    ).map((f) => f.text).toList();

void main() {
  test('flags Text with a literal, const or not', () {
    expect(scan("final a = Text('Sign in'); const b = Text('Cancel');"),
        ['Sign in', 'Cancel']);
  });

  test('flags literal UI arguments', () {
    expect(
      scan("f() => X(title: 'Theme', subtitle: 'On this device', "
          "tooltip: 'Close', hintText: 'Server URL', label: 'Name', "
          "message: 'Saved', semanticLabel: 'Back');"),
      [
        'Theme',
        'On this device',
        'Close',
        'Server URL',
        'Name',
        'Saved',
        'Back'
      ],
    );
  });

  test('flags interpolations with words in them', () {
    expect(scan(r"f(n) => Text('$n devices');"), [r'$n devices']);
  });

  test('allows text without letters and pure interpolation', () {
    expect(scan(r"f(a, b) => Text('$a · $b'); g() => Text('—');"), isEmpty);
  });

  test('allows translated text and keys', () {
    expect(
      scan("f(c) => Text(c.l10n.signIn, key: const Key('sign-in'));"),
      isEmpty,
    );
  });

  test('l10n-ignore on the line exempts it', () {
    expect(scan("f() => Text('Mydia'); // l10n-ignore"), isEmpty);
  });

  test('reports line numbers', () {
    final found = findUntranslated("\n\nf() => Text('Hi');", path: 'y.dart');
    expect(found.single.line, 3);
    expect(found.single.toString(), "y.dart:3  Hi");
  });
}
