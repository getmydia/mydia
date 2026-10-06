import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('nothing in lib/core/cache imports graphql or graphql_flutter', () {
    final offenders = [
      for (final f in Directory('lib/core/cache')
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart')))
        if (RegExp(r"package:graphql(_flutter)?/")
            .hasMatch(f.readAsStringSync()))
          f.path,
    ];
    expect(offenders, isEmpty);
  });
}
