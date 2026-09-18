import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/player/mpv_track_entry.dart';

void main() {
  group('subtitleStreamIndexEntry', () {
    test('pairs a container subtitle track with its stream index', () {
      final entry = subtitleStreamIndexEntry(
        type: 'sub',
        id: '2',
        ffIndex: '4',
        external: 'no',
      );
      expect(entry?.key, '2');
      expect(entry?.value, 4);
    });

    test('skips audio and video tracks', () {
      expect(
        subtitleStreamIndexEntry(
            type: 'audio', id: '1', ffIndex: '1', external: 'no'),
        isNull,
      );
      expect(
        subtitleStreamIndexEntry(
            type: 'video', id: '1', ffIndex: '0', external: 'no'),
        isNull,
      );
    });

    test('skips an external track, whose index points into its own file', () {
      // A server-delivered subtitle reaches mpv through `sub-add`, which
      // makes it external with an `ff-index` of 0. Matching on it would
      // alias the container's stream 0.
      expect(
        subtitleStreamIndexEntry(
            type: 'sub', id: '5', ffIndex: '0', external: 'yes'),
        isNull,
      );
    });

    test('skips an entry mpv reports no index for', () {
      // `getProperty` answers "" for a property the entry does not have.
      expect(
        subtitleStreamIndexEntry(
            type: 'sub', id: '2', ffIndex: '', external: 'no'),
        isNull,
      );
    });

    test('skips an entry with no id or an unreadable index', () {
      expect(
        subtitleStreamIndexEntry(
            type: 'sub', id: '', ffIndex: '4', external: 'no'),
        isNull,
      );
      expect(
        subtitleStreamIndexEntry(
            type: 'sub', id: '2', ffIndex: 'four', external: 'no'),
        isNull,
      );
    });
  });
}
