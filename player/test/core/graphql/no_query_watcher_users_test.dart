import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('no QueryWatcher user outside lib/core/graphql', () {
    final pattern =
        RegExp(r'\b(QueryWatcher|createWatcher|InvalidationRules|QueryKeys)\b');
    // Comments in the cache core still name the watcher they were written
    // beside; only code counts.
    String code(File f) => f
        .readAsLinesSync()
        .where((l) => !l.trimLeft().startsWith('//'))
        .join('\n');
    final offenders = [
      for (final f
          in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') &&
            !f.path.startsWith('lib/core/graphql/') &&
            pattern.hasMatch(code(f)))
          f.path,
    ];
    expect(offenders, isEmpty);
  });
}
