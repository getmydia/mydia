import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The player screen sends no GraphQL data operations of its own; they all
/// go through `PlaybackSession`. Stream sessions (`PlaybackController`) and
/// progress (`ProgressService`) are transport and still take a client.
void main() {
  test('player_screen.dart references no GraphQL documents', () {
    final source = File('lib/presentation/screens/player/player_screen.dart')
        .readAsStringSync();
    expect(RegExp(r'documentNode\w+').allMatches(source).map((m) => m[0]),
        isEmpty);
    expect(source.contains('Query\$'), isFalse);
    expect(source.contains('Mutation\$'), isFalse);
    expect(source.contains('Fragment\$'), isFalse);
  });

  test('the player screen reads no global server state', () {
    final src = File('lib/presentation/screens/player/player_screen.dart')
        .readAsStringSync();
    for (final banned in [
      'GraphQLClient',
      'graphqlClientProvider',
      'connectionProvider',
      'boundMydia',
      'boundSourceId',
      'serverUrlProvider',
      'authTokenProvider',
      'MydiaPlaybackSession(',
    ]) {
      expect(src.contains(banned), isFalse, reason: banned);
    }
  });
}
