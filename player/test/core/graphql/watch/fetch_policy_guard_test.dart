import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Hand-written sources under `lib/`, excluding generated files.
Iterable<File> _sources() {
  return Directory('lib').listSync(recursive: true).whereType<File>().where(
      (file) =>
          file.path.endsWith('.dart') &&
          !file.path.endsWith('.g.dart') &&
          !file.path.endsWith('.freezed.dart') &&
          !file.path.endsWith('.graphql.dart'));
}

/// Drops every line whose trimmed form starts with `//` (this covers both
/// `//` and `///` doc comments in this codebase's style).
///
/// Do not remove this. Without it, a comment that quotes the pattern it
/// warns against — exactly the kind of comment this guard's own rationale
/// invites someone to write, e.g. explaining why `cacheAndNetwork` is safe
/// here because it's paired with `watchQuery` rather than the one-shot
/// `client.query()` API — trips the guard on prose instead of on real code.
/// Stripping keeps the check scoped to code, which is what "guard" means
/// here.
String _stripComments(String source) {
  return source
      .split('\n')
      .where((line) => !line.trim().startsWith('//'))
      .join('\n');
}

void main() {
  test('no file pairs a one-shot client.query with cacheAndNetwork', () {
    // That single enum value in that single call shape is the original bug:
    // the cached result is returned and the network response is written to
    // disk and thrown away.
    final offenders = <String>[];

    for (final file in _sources()) {
      final source = _stripComments(file.readAsStringSync());
      if (source.contains('FetchPolicy.cacheAndNetwork') &&
          source.contains('client.query(')) {
        offenders.add(file.path);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'cacheAndNetwork only works with watchQuery. Use QueryWatcher.',
    );
  });

  test('every file calling watchQuery passes fetchResults: true', () {
    // WatchQueryOptions.fetchResults defaults to false, which produces a
    // watcher that never fetches anything and fails silently.
    final offenders = <String>[];

    for (final file in _sources()) {
      final source = _stripComments(file.readAsStringSync());
      if (source.contains('.watchQuery(') &&
          !source.contains('fetchResults: true')) {
        offenders.add(file.path);
      }
    }

    expect(offenders, isEmpty);
  });
}
