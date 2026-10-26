import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart' show StateProvider;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/l10n/gen/app_localizations_en.dart';
import 'package:player/presentation/screens/home/home_rows.dart';
import 'package:player/presentation/screens/home/home_rows_provider.dart';
import 'package:player/presentation/screens/home/home_scope.dart';

import '../../../domain/merged/fake_merged_source.dart';

void main() {
  /// Pumps the event queue until Home is past loading.
  Future<HomeRows> settled(ProviderContainer c, HomeScope scope) async {
    c.listen(homeRowsProvider(scope), (_, __) {});
    for (var i = 0; i < 50; i++) {
      final rows = c.read(homeRowsProvider(scope));
      final previewsLoaded = rows.libraries.every((r) => r.items.isNotEmpty);
      if (!rows.loading && previewsLoaded) return rows;
      await pumpEventQueue();
    }
    return c.read(homeRowsProvider(scope));
  }

  ProviderContainer containerFor(List<FakeMergedSource> sources) {
    final c = ProviderContainer(overrides: [
      allServersSourcesProvider.overrideWithValue(sources),
      for (final s in sources) mediaSourceProvider(s.id).overrideWithValue(s),
    ]);
    addTearDown(c.dispose);
    return c;
  }

  FakeMergedSource server(String id) {
    final s = fakeServer(id);
    return FakeMergedSource(
      s,
      movies: [item(s, '${id}m', addedAt: DateTime.utc(2024))],
      resuming: [item(s, '${id}r', lastPlayedAt: DateTime.utc(2024))],
      recent: [item(s, '${id}n', addedAt: DateTime.utc(2024))],
      favs: [item(s, '${id}f')],
    );
  }

  test('one server: every row, libraries included, unlabelled', () async {
    final a = server('a');
    final rows = await settled(containerFor([a]), OneServer(a.id));
    expect(rows.continueWatching.single.ref.externalId, 'ar');
    expect(rows.recentMovies.single.ref.externalId, 'an');
    expect(rows.favorites.single.ref.externalId, 'af');
    expect(rows.libraries.single.title(AppLocalizationsEn()), 'Films');
    expect(rows.libraries.single.items.single.ref.externalId, 'am');
    expect(rows.labelled, isFalse);
  });

  test('all servers: both servers merged and labelled', () async {
    final a = server('a'), b = server('b');
    final rows = await settled(containerFor([a, b]), const AllServers());
    expect(rows.continueWatching, hasLength(2));
    expect(rows.libraries.map((r) => r.title(AppLocalizationsEn())),
        ['Films · Server a', 'Films · Server b']);
  });

  test('one server of two shows only that server', () async {
    final a = server('a'), b = server('b');
    final rows = await settled(containerFor([a, b]), OneServer(b.id));
    expect(rows.continueWatching.map((i) => i.ref.externalId), ['br']);
    expect(rows.names.keys, [b.id]);
  });

  test('a server leaving All servers drops its items', () async {
    final a = server('a'), b = server('b');
    final included = StateProvider<List<FakeMergedSource>>((_) => [a, b]);
    final c = ProviderContainer(overrides: [
      allServersSourcesProvider.overrideWith((ref) => ref.watch(included)),
      for (final s in [a, b]) mediaSourceProvider(s.id).overrideWithValue(s),
    ]);
    addTearDown(c.dispose);
    await settled(c, const AllServers());
    c.read(included.notifier).state = [a];
    final rows = await settled(c, const AllServers());
    expect(rows.continueWatching.map((i) => i.ref.sourceId).toSet(), {a.id});
  });

  test('query keys cover the four feeds of every server', () {
    final keys = homeQueryKeys([fakeServer('a').id]);
    expect(keys, hasLength(4));
  });

  test('scopes compare by value', () {
    expect(const AllServers(), const AllServers());
    expect(OneServer(fakeServer('a').id), OneServer(fakeServer('a').id));
    expect(OneServer(fakeServer('a').id), isNot(const AllServers()));
  });
}
