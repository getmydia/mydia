import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/freshness.dart';
import 'package:player/core/cache/query_key.dart';

void main() {
  final now = DateTime(2026, 7, 28, 12, 0);

  group('Freshness.combine', () {
    test('combining is optimistic about time and pessimistic about state', () {
      final older = now.subtract(const Duration(hours: 2));
      final combined = Freshness.combine([
        Freshness(fetchedAt: now, isStale: false),
        Freshness(fetchedAt: older, isStale: true, refreshFailed: true),
      ]);

      expect(combined.fetchedAt, older, reason: 'oldest wins');
      expect(combined.isStale, isTrue);
      expect(combined.refreshFailed, isTrue);
    });

    test('combining nothing yields an empty freshness', () {
      expect(Freshness.combine(const []), const Freshness());
    });
  });

  group('FreshnessRegistry', () {
    test('publish exposes state per key and clear removes it', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final registry = container.read(freshnessRegistryProvider.notifier);
      const state = Freshness(isRefreshing: true);
      final key = QueryKey('HomeScreen');

      registry.publish(key, state);
      expect(container.read(freshnessRegistryProvider)[key], state);

      registry.clear(key);
      expect(container.read(freshnessRegistryProvider)[key], isNull);
    });
  });
}
