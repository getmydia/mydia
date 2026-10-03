import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/sources/capabilities.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/domain/sources/library.dart';

class ContractFixture {
  ContractFixture({
    required this.source,
    required this.library,
    required this.playable,
    required this.libraryItemCount,
  });

  final MediaSource source;
  final LibraryRef library;

  /// A movie or video with one playable version.
  final ItemRef playable;
  final int libraryItemCount;
}

/// What every Plex and Stash implementation must do, over that source's
/// recorded fixtures.
void runMediaSourceContract(
  String name,
  Future<ContractFixture> Function() setUp,
) {
  group('$name MediaSource contract', () {
    test('lists the fixture library', () async {
      final f = await setUp();
      final libraries = await f.source.libraries();
      expect(libraries.map((l) => l.ref), contains(f.library));
      expect(libraries.firstWhere((l) => l.ref == f.library).sortOptions,
          isNotEmpty);
    });

    test('pages a library to the end without repeats', () async {
      final f = await setUp();
      final seen = <ItemRef>[];
      Cursor? cursor;
      var pages = 0;
      do {
        final page = await f.source.browse(
          f.library,
          const BrowseQuery(pageSize: 2),
          cursor: cursor,
        );
        seen.addAll(page.items.map((i) => i.ref));
        cursor = page.nextCursor;
        pages++;
      } while (cursor != null && pages < 20);
      expect(seen.toSet(), hasLength(seen.length));
      expect(seen, hasLength(f.libraryItemCount));
      expect(pages, greaterThan(1));
    });

    test('item detail carries a playable version', () async {
      final f = await setUp();
      final detail = await f.source.item(f.playable);
      expect(detail.summary.ref, f.playable);
      expect(detail.versions, isNotEmpty);
      expect(detail.versions.first.id, isNotEmpty);
    });

    test('artwork keeps the credential out of the URL and the cache key',
        () async {
      final f = await setUp();
      final detail = await f.source.item(f.playable);
      final art = detail.summary.poster;
      expect(art, isNotNull);
      final request = await f.source.artwork(art!, width: 300);
      expect(request, isNotNull);
      expect(Uri.parse(request!.url).hasScheme, isTrue);
      for (final secret in request.headers.values) {
        expect(request.url, isNot(contains(secret)));
        expect(request.cacheKey, isNot(contains(secret)));
      }
      final again = await f.source.artwork(art, width: 300);
      expect(again!.cacheKey, request.cacheKey);
    });

    test('declared capabilities resolve, undeclared ones do not', () async {
      final f = await setUp();
      final caps = f.source.capabilities;
      expect(f.source.as<WatchedState>() != null,
          caps.contains(SourceCapability.watchedState));
      expect(f.source.as<Searchable>() != null,
          caps.contains(SourceCapability.searchable));
    });
  });
}
