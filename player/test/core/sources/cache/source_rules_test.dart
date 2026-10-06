import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/invalidation_target.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/cache/source_rules.dart';
import 'package:player/core/sources/source.dart';

const _a = SourceId('acc1:owner:srv1');

Set<String> _ops(Set<InvalidationTarget> targets) => {
      for (final t in targets)
        (t as FamilyTarget).operationName.split('/').last,
    };

void main() {
  test('every operation that carries watch state is in watchedChanged', () {
    // Only `libraries` returns no items. Adding a new operation to
    // SourceOps.all without deciding its rule fails here.
    expect(_ops(SourceRules.watchedChanged(_a)),
        SourceOps.all.difference({SourceOps.libraries}));
  });

  test('rules stay on their own source', () {
    for (final target in [
      ...SourceRules.watchedChanged(_a),
      ...SourceRules.favoriteChanged(_a),
      ...SourceRules.continueWatchingRemoved(_a),
    ]) {
      expect((target as FamilyTarget).operationName,
          startsWith('acc1:owner:srv1/'));
    }
  });

  test('favorite and continue watching rules are narrow', () {
    expect(_ops(SourceRules.favoriteChanged(_a)),
        {SourceOps.item, SourceOps.browse, SourceOps.hubs});
    expect(_ops(SourceRules.continueWatchingRemoved(_a)),
        {SourceOps.continueWatching, SourceOps.hubs});
    expect(SourceRules.progressSynced, isEmpty);
  });
}
