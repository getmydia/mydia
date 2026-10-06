import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

Iterable<File> _libFiles() => Directory('lib')
    .listSync(recursive: true)
    .whereType<File>()
    .where((f) => f.path.endsWith('.dart'));

void main() {
  test('nothing in lib elects one Mydia instance', () {
    final pattern = RegExp(
        r'\bbound(Mydia\w*|SourceId|AccountId)Provider\b|\bbound_mydia\b');
    final offenders = [
      for (final f in _libFiles())
        if (pattern.hasMatch(f.readAsStringSync())) f.path,
    ];
    expect(offenders, isEmpty);
  });

  test('only the legacy redirect reads the legacy id provider', () {
    final readers = [
      for (final f in _libFiles())
        if (f.readAsStringSync().contains('legacyInstanceIdProvider')) f.path,
    ];
    expect(readers, ['lib/core/router/legacy_routes.dart']);
  });
}
