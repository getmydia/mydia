import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/sources/playback_sequence.dart';

void main() {
  test('round-trips every origin', () {
    for (final origin in SequenceOrigin.values) {
      final s = PlaybackSequence(
        origin: origin,
        position: 7,
        sortId: 'date',
        descending: true,
        filterIds: const {'b', 'a'},
        query: 'sunset beach',
      );
      expect(PlaybackSequence.fromQuery(s.toQuery()), s);
    }
  });

  test('round-trips descending false', () {
    const s = PlaybackSequence(
      origin: SequenceOrigin.library,
      position: 0,
      descending: false,
    );
    expect(s.toQuery()['seqDesc'], '0');
    expect(PlaybackSequence.fromQuery(s.toQuery()), s);
  });

  test('sorts filter ids', () {
    const s = PlaybackSequence(
      origin: SequenceOrigin.library,
      position: 1,
      filterIds: {'b', 'a'},
    );
    expect(s.toQuery()['seqFilter'], 'a,b');
  });

  test('omits unset fields', () {
    expect(
      const PlaybackSequence(
        origin: SequenceOrigin.continueWatching,
        position: 3,
      ).toQuery(),
      {'seq': 'continueWatching', 'seqPos': '3'},
    );
  });

  test('rejects malformed', () {
    for (final q in <Map<String, String>>[
      {},
      {'seq': 'bogus', 'seqPos': '1'},
      {'seq': 'library'},
      {'seq': 'library', 'seqPos': '-1'},
      {'seq': 'library', 'seqPos': 'x'},
    ]) {
      expect(PlaybackSequence.fromQuery(q), isNull, reason: '$q');
    }
  });

  test('at() moves only the position', () {
    const s = PlaybackSequence(
      origin: SequenceOrigin.search,
      position: 2,
      sortId: 'x',
      query: 'q',
    );
    expect(
      s.at(5),
      const PlaybackSequence(
        origin: SequenceOrigin.search,
        position: 5,
        sortId: 'x',
        query: 'q',
      ),
    );
  });
}
