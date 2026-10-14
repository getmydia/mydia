import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/router/detail_location.dart';

void main() {
  group('isDetailLocation', () {
    test('matches movie, show, season and episode pages', () {
      for (final kind in ['movie', 'show', 'season', 'episode']) {
        expect(isDetailLocation('/s/acc1:owner:aa11/$kind/m1'), isTrue, //
            reason: kind);
      }
    });

    test('ignores a query string and keeps encoded ids as one segment', () {
      expect(isDetailLocation('/s/a%2Fb/movie/x%201?tab=cast'), isTrue);
    });

    test('rejects everything else', () {
      expect(isDetailLocation('/'), isFalse);
      expect(isDetailLocation('/s/acc1'), isFalse);
      expect(isDetailLocation('/s/acc1/library/l1'), isFalse);
      expect(isDetailLocation('/s/acc1/item/movie/m1'), isFalse);
      expect(isDetailLocation('/s/acc1/player/m1'), isFalse);
      expect(isDetailLocation('/s/acc1/collection/c1'), isFalse);
      expect(isDetailLocation('/s/acc1/movie'), isFalse);
      expect(isDetailLocation('/s/acc1/movie/m1/extra'), isFalse);
      expect(isDetailLocation('/movie/1'), isFalse);
    });
  });

  group('shellNavLocation', () {
    test('a non-detail location is its own', () {
      expect(shellNavLocation('/s/a/favorites', origin: '/'), '/s/a/favorites');
    });

    test('a detail page borrows the page it was opened from', () {
      expect(
        shellNavLocation('/s/a/movie/m1', origin: '/s/a/favorites'),
        '/s/a/favorites',
      );
      expect(shellNavLocation('/s/a/movie/m1', origin: '/all'), '/all');
    });

    test('a deep link with no origin keeps the detail location', () {
      expect(shellNavLocation('/s/a/movie/m1'), '/s/a/movie/m1');
    });

    test('an origin on another source is ignored', () {
      expect(
        shellNavLocation('/s/b/movie/m1', origin: '/s/a/favorites'),
        '/s/b/movie/m1',
      );
    });
  });
}
