import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final banned = RegExp(r"package:graphql(_flutter)?/");

  for (final dir in ['lib', 'test', 'integration_test']) {
    test('$dir imports no GraphQL client package', () {
      final offenders = [
        for (final f
            in Directory(dir).listSync(recursive: true).whereType<File>())
          if (f.path.endsWith('.dart') &&
              !f.path.endsWith('no_graphql_client_test.dart') &&
              banned.hasMatch(f.readAsStringSync()))
            f.path,
      ];
      expect(offenders, isEmpty);
    });
  }

  test('pubspec has no GraphQL client dependency', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
        RegExp(r'^\s+graphql(_flutter)?:', multiLine: true).hasMatch(pubspec),
        isFalse);
  });
}
