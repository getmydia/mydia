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
final RegExp _fragmentDeclaration =
    RegExp(r'\bfragment\s+([A-Za-z0-9_]+)\s+on\s+[A-Za-z0-9_]+\s*\{');
final RegExp _fragmentSpread = RegExp(r'\.\.\.([A-Za-z0-9_]+)');

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

Iterable<File> _sourceFiles(Directory root) =>
    root.listSync(recursive: true).whereType<File>().where((file) =>
        file.path.endsWith('.dart') || file.path.endsWith('.graphql'));

/// One `query` or `fragment` declaration's name and the source slice it
/// owns: from its own start to the start of the next declaration of either
/// kind in the same file, or to the end of the file.
///
/// Bounding on both kinds (not just [pattern]'s own kind) keeps a fragment
/// declared between two queries in the same file from bleeding into either
/// query's slice, and a query from bleeding into a fragment's. The slice
/// itself is still a coarse split that errs toward over-reporting: a false
/// positive is a visible failure someone must consciously allowlist, which
/// is what keeps the invariant honest.
Map<String, String> _declarationSlices(String source, RegExp pattern) {
  final allStarts = <int>[
    ..._queryDeclaration.allMatches(source).map((m) => m.start),
    ..._fragmentDeclaration.allMatches(source).map((m) => m.start),
  ]..sort();

  final slices = <String, String>{};
  for (final match in pattern.allMatches(source)) {
    final next = allStarts.firstWhere(
      (start) => start > match.start,
      orElse: () => source.length,
    );
    slices[match.group(1)!] = source.substring(match.start, next);
  }
  return slices;
}

/// Every fragment name whose selection set renders watch state, directly or
/// through another watch-state fragment it spreads.
///
/// Resolved to a fixed point rather than in one pass, so a fragment that
/// only spreads a watch-state fragment (and holds no literal field of its
/// own) still counts — `season_episodes.graphql`'s `progress { ...
/// ProgressFragment }` is exactly that shape. The round count is capped at
/// the number of fragments found, which bounds a fixed point over a finite
/// graph regardless of cycles: a self- or mutually-referential spread simply
/// stops contributing once no round adds anything new, so a malformed
/// fragment file cannot hang the suite.
Set<String> _watchStateFragments(Directory root) {
  final bodies = <String, String>{};
  for (final file in _sourceFiles(root)) {
    bodies.addAll(
      _declarationSlices(file.readAsStringSync(), _fragmentDeclaration),
    );
  }

  final watchState = <String>{
    for (final entry in bodies.entries)
      if (_watchStateFields.any(entry.value.contains)) entry.key,
  };

  var changedThisRound = true;
  var round = 0;
  while (changedThisRound && round < bodies.length) {
    changedThisRound = false;
    round++;
    for (final entry in bodies.entries) {
      if (watchState.contains(entry.key)) continue;
      final spreadsWatchState = _fragmentSpread
          .allMatches(entry.value)
          .map((match) => match.group(1)!)
          .any(watchState.contains);
      if (spreadsWatchState) {
        watchState.add(entry.key);
        changedThisRound = true;
      }
    }
  }

  return watchState;
}

/// Every operation whose document selects a watch-state field, either
/// literally or by spreading a fragment that does (directly or
/// transitively — see [_watchStateFragments]).
///
/// Scans `.dart` as well as `.graphql`, because inline query strings skip
/// codegen validation in this repo and are exactly where a new uncovered
/// query would appear. [root] defaults to `lib`; tests exercising the
/// fragment resolution point it at a throwaway fixture directory instead, so
/// they can pin the behavior without depending on the shape of the real
/// codebase.
Set<String> _watchStateOperations([Directory? root]) {
  final directory = root ?? Directory('lib');
  final watchStateFragments = _watchStateFragments(directory);
  final operations = <String>{};

  for (final file in _sourceFiles(directory)) {
    final slices =
        _declarationSlices(file.readAsStringSync(), _queryDeclaration);

    for (final entry in slices.entries) {
      final rendersWatchState = _watchStateFields.any(entry.value.contains) ||
          _fragmentSpread
              .allMatches(entry.value)
              .map((match) => match.group(1)!)
              .any(watchStateFragments.contains);

      if (rendersWatchState) {
        operations.add(entry.key);
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

  group('fragment-aware detection', () {
    // A capability with no test is a claim: these pin that a query which
    // renders watch state only through a fragment spread is still caught,
    // not just one that spells the field out literally. Run against a
    // throwaway fixture directory rather than lib/, so the assertions do not
    // depend on which real query happens to be shaped this way today.
    late Directory fixture;

    setUp(() {
      fixture = Directory.systemTemp.createTempSync('invalidation_coverage_');
    });

    tearDown(() {
      fixture.deleteSync(recursive: true);
    });

    void write(String name, String contents) {
      File('${fixture.path}/$name').writeAsStringSync(contents);
    }

    test('a query that only spreads a watch-state fragment is detected', () {
      write('fragment.graphql', '''
fragment DirectWatchFragment on Progress {
  watched
}
''');
      write('query.graphql', '''
query SpreadOnlyQuery(\$id: ID!) {
  thing(id: \$id) {
    progress {
      ...DirectWatchFragment
    }
  }
}
''');

      expect(_watchStateOperations(fixture), contains('SpreadOnlyQuery'));
    });

    test(
        'a query spreading a fragment that itself only spreads a '
        'watch-state fragment is still detected (transitive resolution)', () {
      write('fragments.graphql', '''
fragment DirectWatchFragment on Progress {
  watched
}

fragment IndirectWatchFragment on Progress {
  ...DirectWatchFragment
}
''');
      write('query.graphql', '''
query TransitiveSpreadQuery(\$id: ID!) {
  thing(id: \$id) {
    progress {
      ...IndirectWatchFragment
    }
  }
}
''');

      expect(_watchStateOperations(fixture), contains('TransitiveSpreadQuery'));
    });

    test(
        'a query spreading a fragment with no watch-state field is not '
        'detected', () {
      write('fragment.graphql', '''
fragment PlainFragment on Progress {
  durationSeconds
}
''');
      write('query.graphql', '''
query PlainQuery(\$id: ID!) {
  thing(id: \$id) {
    progress {
      ...PlainFragment
    }
  }
}
''');

      expect(_watchStateOperations(fixture), isNot(contains('PlainQuery')));
    });

    test(
        'a self-referential fragment spread with no watch-state field '
        'resolves to not-detected instead of hanging', () {
      write('fragment.graphql', '''
fragment CyclicFragment on Progress {
  ...CyclicFragment
}
''');
      write('query.graphql', '''
query CyclicQuery(\$id: ID!) {
  thing(id: \$id) {
    progress {
      ...CyclicFragment
    }
  }
}
''');

      expect(_watchStateOperations(fixture), isNot(contains('CyclicQuery')));
    });

    test(
        'a mutually-referential fragment cycle that also carries a real '
        'watch-state field is still detected, not short-circuited by the '
        'cycle guard', () {
      write('fragments.graphql', '''
fragment DirectWatchFragment on Progress {
  watched
}

fragment CyclicA on Progress {
  ...CyclicB
  ...DirectWatchFragment
}

fragment CyclicB on Progress {
  ...CyclicA
}
''');
      write('query.graphql', '''
query CyclicWithWatchQuery(\$id: ID!) {
  thing(id: \$id) {
    progress {
      ...CyclicB
    }
  }
}
''');

      expect(
        _watchStateOperations(fixture),
        contains('CyclicWithWatchQuery'),
      );
    });
  });
}
