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

/// Every `query`/`fragment` declaration across [root]'s `.dart` and
/// `.graphql` files, grouped by name — keeping every declaration for a name
/// rather than collapsing to one.
///
/// A name can legitimately declare more than once: `RecentlyAddedFull` in
/// `recently_added_controller.dart` has a primary shape and a
/// `...Legacy` fallback for a server older than this build, and only the
/// primary selects `watchStatus`. `HomeScreen` and `ContinueWatchingList`
/// have the same primary-plus-legacy shape. Collapsing to a single body per
/// name (whichever declaration a map write happens to see last) can
/// silently lose the one declaration that actually renders watch state —
/// which is exactly what happened here before this fixed it: keying by name
/// in a plain `Map<String, String>` meant the legacy `RecentlyAddedFull`,
/// declared second and selecting nothing, overwrote the primary one, and
/// the guard stopped protecting the very screen this branch exists to fix.
///
/// [pattern] selects which kind of declaration to collect
/// ([_queryDeclaration] or [_fragmentDeclaration]); a slice still runs to
/// the start of the next declaration of *either* kind in the same file (not
/// just [pattern]'s own kind), so a fragment sitting between two queries in
/// the same file cannot bleed into either query's slice, and vice versa.
Map<String, List<String>> _declarationBodies(Directory root, RegExp pattern) {
  final bodies = <String, List<String>>{};

  for (final file in _sourceFiles(root)) {
    final source = file.readAsStringSync();
    final allStarts = <int>[
      ..._queryDeclaration.allMatches(source).map((m) => m.start),
      ..._fragmentDeclaration.allMatches(source).map((m) => m.start),
    ]..sort();

    for (final match in pattern.allMatches(source)) {
      final next = allStarts.firstWhere(
        (start) => start > match.start,
        orElse: () => source.length,
      );
      bodies
          .putIfAbsent(match.group(1)!, () => [])
          .add(source.substring(match.start, next));
    }
  }

  return bodies;
}

/// Every fragment name whose selection set renders watch state, directly or
/// through another watch-state fragment it spreads.
///
/// A name counts if *any* of its declarations qualifies — see
/// [_declarationBodies] — not just the last one scanned. Cross-file
/// duplicates are latent only, since GraphQL requires fragment names to be
/// unique across a codegen document set or generation fails, but grouping
/// (rather than the `Map.addAll` last-write-wins this replaced) keeps this
/// function's collection order-independent like every other set here.
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
  final bodies = _declarationBodies(root, _fragmentDeclaration);

  final watchState = <String>{
    for (final entry in bodies.entries)
      if (entry.value.any((body) => _watchStateFields.any(body.contains)))
        entry.key,
  };

  var changedThisRound = true;
  var round = 0;
  while (changedThisRound && round < bodies.length) {
    changedThisRound = false;
    round++;
    for (final entry in bodies.entries) {
      if (watchState.contains(entry.key)) continue;
      final spreadsWatchState = entry.value.any(
        (body) => _fragmentSpread
            .allMatches(body)
            .map((match) => match.group(1)!)
            .any(watchState.contains),
      );
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
/// A name counts if *any* of its declarations qualifies — see
/// [_declarationBodies] — so a primary-plus-legacy pair like
/// `RecentlyAddedFull` is still caught even though only the primary
/// declaration selects a watch field.
///
/// Scans `.dart` as well as `.graphql`, because inline query strings skip
/// codegen validation in this repo and are exactly where a new uncovered
/// query would appear. [root] defaults to `lib`; tests exercising the
/// fragment resolution and duplicate-declaration handling point it at a
/// throwaway fixture directory instead, so they can pin the behavior
/// without depending on the shape of the real codebase.
Set<String> _watchStateOperations([Directory? root]) {
  final directory = root ?? Directory('lib');
  final watchStateFragments = _watchStateFragments(directory);
  final bodies = _declarationBodies(directory, _queryDeclaration);

  return {
    for (final entry in bodies.entries)
      if (entry.value.any(
        (body) =>
            _watchStateFields.any(body.contains) ||
            _fragmentSpread
                .allMatches(body)
                .map((match) => match.group(1)!)
                .any(watchStateFragments.contains),
      ))
        entry.key,
  };
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
  // Shared by every fixture-backed test below (fragment resolution and
  // duplicate-declaration handling alike): a throwaway directory so those
  // assertions pin the scan's behavior directly, without depending on which
  // real query in lib/ happens to be shaped a particular way today.
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

  test('RecentlyAddedFull is detected despite its primary-plus-legacy shape',
      () {
    // The concrete case Finding 1 was about, run against the real tree
    // rather than a fixture: recently_added_controller.dart declares
    // RecentlyAddedFull twice, and only the primary (declared first)
    // selects watchStatus. This must both be detected as watch-state AND
    // still pass the main assertion above, since recentlyAdded is genuinely
    // covered by the three watched rules already.
    expect(_watchStateOperations(), contains('RecentlyAddedFull'));
  });

  group('fragment-aware detection', () {
    // A capability with no test is a claim: these pin that a query which
    // renders watch state only through a fragment spread is still caught,
    // not just one that spells the field out literally.
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

  group('duplicate declaration handling', () {
    // Finding 1: a second declaration of the same operation name used to
    // overwrite the first in a plain Map<String, String>, so a primary
    // declaration that renders watch state could be silently discarded by a
    // later, unrelated declaration reusing its name — exactly
    // RecentlyAddedFull's primary-plus-legacy shape in production, pinned
    // directly against the real tree above. Here the watch-state
    // declaration is deliberately FIRST and the non-watch-state one SECOND,
    // so this genuinely fails against last-write-wins: if it were the other
    // way around a buggy scan would pass by coincidence and prove nothing.
    test(
        'a query name declared twice is still detected when only the '
        'first declaration renders watch state', () {
      write('query.graphql', '''
query DuplicateNameQuery(\$first: Int) {
  things(first: \$first) {
    watchStatus { watched percentage }
  }
}

query DuplicateNameQuery(\$first: Int) {
  things(first: \$first) {
    id
  }
}
''');

      expect(_watchStateOperations(fixture), contains('DuplicateNameQuery'));
    });

    // Finding 2: the same last-write-wins shape existed one level down, in
    // how fragment bodies were merged across files. Latent in practice —
    // GraphQL requires fragment names to be unique across a codegen
    // document set — but fixed for the same reason and pinned here anyway,
    // since the underlying helper is now shared between queries and
    // fragments.
    test(
        'a fragment name declared twice is still detected when only the '
        'first declaration renders watch state', () {
      write('fragments.graphql', '''
fragment DuplicateNameFragment on Progress {
  watched
}

fragment DuplicateNameFragment on Progress {
  durationSeconds
}
''');
      write('query.graphql', '''
query SpreadsDuplicateFragmentQuery(\$id: ID!) {
  thing(id: \$id) {
    progress {
      ...DuplicateNameFragment
    }
  }
}
''');

      expect(
        _watchStateOperations(fixture),
        contains('SpreadsDuplicateFragmentQuery'),
      );
    });
  });
}
