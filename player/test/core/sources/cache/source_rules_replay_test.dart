import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/invalidation_target.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/cache/source_rules.dart';
import 'package:player/core/sources/source.dart';

const _a = SourceId('acc1:owner:srv1');

Set<String> _ops(Set<InvalidationTarget> t) => {
      for (final x in t)
        if (x case FamilyTarget(:final operationName))
          operationName.split('/').last,
    };

void main() {
  group('InvalidationRules replayed against the Mydia source ops', () {
    test(
        'watchedChanged (episode): shows grid, unwatched, favorites, '
        'continue watching, recently added, collections, show, season', () {
      expect(
        _ops(SourceRules.watchedChanged(_a)),
        containsAll(<String>{
          SourceOps.hubs,
          SourceOps.continueWatching,
          SourceOps.browse,
          SourceOps.unwatched,
          SourceOps.favorites,
          SourceOps.recentlyAdded,
          SourceOps.collectionItems,
          SourceOps.item,
          SourceOps.children,
        }),
      );
    });

    test('movieWatchedChanged: movies grid and the movie itself', () {
      expect(_ops(SourceRules.watchedChanged(_a)),
          containsAll(<String>{SourceOps.browse, SourceOps.item}));
    });

    test('playbackFinished: the same set as watchedChanged', () {
      expect(_ops(SourceRules.offlineProgressSynced(_a)),
          _ops(SourceRules.watchedChanged(_a)));
    });

    test('favoriteToggled: favorites, home, grid, and the item itself', () {
      expect(
        _ops(SourceRules.favoriteChanged(_a)),
        containsAll(<String>{
          SourceOps.favorites,
          SourceOps.hubs,
          SourceOps.browse,
          SourceOps.item,
        }),
      );
    });

    test('continueWatchingRemoved: the rail and home only', () {
      expect(_ops(SourceRules.continueWatchingRemoved(_a)),
          {SourceOps.continueWatching, SourceOps.hubs});
    });

    test('nothing reaches another source', () {
      for (final t in SourceRules.watchedChanged(_a)) {
        expect((t as FamilyTarget).operationName, startsWith('${_a.value}/'));
      }
    });
  });
}
