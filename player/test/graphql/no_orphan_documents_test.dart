import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('every operation document is used outside lib/graphql', () {
    final op = RegExp(r'^\s*(query|mutation)\s+(\w+)', multiLine: true);
    final sources = [
      for (final f
          in Directory('lib').listSync(recursive: true).whereType<File>())
        if (f.path.endsWith('.dart') &&
            !f.path.endsWith('.graphql.dart') &&
            !f.path.startsWith('lib/graphql/'))
          f.readAsStringSync(),
    ].join('\n');
    final orphans = [
      for (final f in Directory('lib/graphql')
          .listSync(recursive: true)
          .whereType<File>())
        if (f.path.endsWith('.graphql') && !f.path.endsWith('schema.graphql'))
          for (final m in op.allMatches(f.readAsStringSync()))
            // The generated constant is what a caller sends, so a bare mention
            // of the name (a comment, a class like Query$Name) is not a use.
            if (!RegExp('documentNode${_kind(m.group(1)!)}${m.group(2)!}\\b')
                .hasMatch(sources))
              '${f.path}: ${m.group(2)}',
    ];
    expect(orphans, isEmpty);
  });
}

String _kind(String keyword) => keyword == 'query' ? 'Query' : 'Mutation';
