import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The screen builds no transport and no progress writer of its own; the
/// session does. Textual, like the PR 1 GraphQL guard beside it.
void main() {
  test('player_screen.dart constructs no Mydia transport or progress', () {
    final source = File('lib/presentation/screens/player/player_screen.dart')
        .readAsStringSync();
    for (final constructor in [
      'PlaybackController(',
      'ProgressService(',
      'HttpStreamUrls(',
      'ProxyStreamUrls(',
    ]) {
      expect(source.contains(constructor), isFalse, reason: constructor);
    }
  });
}
