import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/graphql/watch/invalidation_rules.dart';
import 'package:player/core/graphql/watch/invalidation_target.dart';

/// Operations that render watch state and are deliberately not invalidated
/// when it changes. Empty on purpose: there is no such operation today, and
/// adding one should be a conscious, reviewed act rather than an omission.
const Set<String> _intentionallyUncovered = <String>{};

/// Selecting any of these means the document renders watch state.
const List<String> _watchStateFields = [
  'watched',
  'positionSeconds',
  'percentage',
];

final RegExp _queryKeyDeclaration = RegExp(r"QueryKey\(\s*'([A-Za-z0-9_]+)'");
final RegExp _queryDeclaration = RegExp(r'\bquery\s+([A-Za-z0-9_]+)\s*[({]');

/// Every operation name that has a `QueryKey` declared for it.
///
/// An operation with no key is not under the invalidation system's control at
/// all, so holding a rule responsible for it would be a false positive.
Set<String> _declaredOperations() {
  final source =
      File('lib/core/graphql/watch/query_key.dart').readAsStringSync();

  return _queryKeyDeclaration
      .allMatches(source)
      .map((match) => match.group(1)!)
      .toSet();
}

/// Every operation whose document selects a watch-state field.
///
/// Scans `.dart` as well as `.graphql`, because inline query strings skip
/// codegen validation in this repo and are exactly where a new uncovered
/// query would appear. Each `query Name(` starts a slice that runs to the next
/// declaration, which is a coarse split that errs toward over-reporting: a
/// false positive is a visible failure someone must consciously allowlist,
/// which is what keeps the invariant honest.
Set<String> _watchStateOperations() {
  final operations = <String>{};
  final files = Directory('lib')
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) =>
          file.path.endsWith('.dart') || file.path.endsWith('.graphql'));

  for (final file in files) {
    final source = file.readAsStringSync();
    final declarations = _queryDeclaration.allMatches(source).toList();

    for (var i = 0; i < declarations.length; i++) {
      final start = declarations[i].start;
      final end = i + 1 < declarations.length
          ? declarations[i + 1].start
          : source.length;
      final body = source.substring(start, end);

      if (_watchStateFields.any(body.contains)) {
        operations.add(declarations[i].group(1)!);
      }
    }
  }

  return operations;
}

/// Every operation named by a rule that fires when watch state changes.
Set<String> _operationsCoveredByWatchedRules() {
  final rules = <Set<InvalidationTarget>>[
    InvalidationRules.watchedChanged(showId: 's1', seasonNumber: 1),
    InvalidationRules.movieWatchedChanged(movieId: 'm1'),
    InvalidationRules.playbackFinished(
      mediaType: 'episode',
      mediaId: 'e1',
      showId: 's1',
    ),
    InvalidationRules.playbackFinished(mediaType: 'movie', mediaId: 'm1'),
  ];

  return rules
      .expand((targets) => targets)
      .map((target) => switch (target) {
            KeyTarget(:final key) => key.operationName,
            FamilyTarget(:final operationName) => operationName,
          })
      .toSet();
}

void main() {
  test('the scan reaches the player sources', () {
    // Without this, a change to the test working directory would turn every
    // assertion below into a vacuous pass and quietly retire the guard.
    expect(
      _declaredOperations(),
      isNotEmpty,
      reason: 'found no QueryKey declarations; is the test cwd the player '
          'package root?',
    );
    expect(
      _watchStateOperations(),
      isNotEmpty,
      reason: 'found no query selecting a watch-state field; the scan is '
          'not seeing lib/',
    );
  });

  test('every query that renders watch state is invalidated when it changes',
      () {
    final uncovered = _watchStateOperations()
        .intersection(_declaredOperations())
        .difference(_operationsCoveredByWatchedRules())
        .difference(_intentionallyUncovered);

    expect(
      uncovered,
      isEmpty,
      reason:
          'These operations select a watch-state field and have a QueryKey, '
          'but no rule in InvalidationRules refreshes them when watch state '
          'changes, so their screens go stale: $uncovered. Add each to '
          'watchedChanged, movieWatchedChanged and playbackFinished, or to '
          '_intentionallyUncovered with a comment saying why.',
    );
  });
}
