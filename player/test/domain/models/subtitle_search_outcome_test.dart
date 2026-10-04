import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/subtitle_search_outcome.dart' as domain;
import 'package:player/presentation/widgets/subtitle_track_selector.dart'
    as widget;

void main() {
  test('the selector re-exports the domain types, not copies of them', () {
    const outcome = domain.SubtitleSearchOutcome(results: [], providers: []);
    expect(outcome, isA<widget.SubtitleSearchOutcome>());
    const error = domain.SubtitleActionException('Search again.');
    expect(error, isA<widget.SubtitleActionException>());
    expect(error.message, 'Search again.');
  });

  test('the session interface no longer imports a widget file', () {
    final source = File(
      'lib/presentation/screens/player/session/playback_session.dart',
    ).readAsStringSync();
    expect(source.contains('widgets/'), isFalse);
  });
}
