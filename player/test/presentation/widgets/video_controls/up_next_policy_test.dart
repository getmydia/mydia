import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/media_segment.dart';
import 'package:player/presentation/widgets/video_controls/up_next_policy.dart';

void main() {
  group('shouldOfferUpNext', () {
    const duration = Duration(minutes: 45);
    const credits = MediaSegment(
      type: SegmentType.credits,
      startMs: 2640000, // 44:00
      endMs: 2700000, // 45:00
    );

    test('is false before credits start, even in the old 90% window', () {
      // 40:30 into a 45-minute episode: past the old 90% threshold
      // (40:30 = 90% of 45:00) but two and a half minutes before the
      // detected credits actually begin.
      expect(
        shouldOfferUpNext(
          segments: [credits],
          position: const Duration(minutes: 40, seconds: 30),
          duration: duration,
        ),
        isFalse,
      );
    });

    test('is true once playback reaches the credits segment', () {
      expect(
        shouldOfferUpNext(
          segments: [credits],
          position: const Duration(minutes: 44),
          duration: duration,
        ),
        isTrue,
      );
    });

    test('is true past the credits start even outside the fallback window', () {
      // A credits segment is authoritative regardless of how far from the
      // real end it sits.
      const earlyCredits = MediaSegment(
        type: SegmentType.credits,
        startMs: 600000, // 10:00
        endMs: 660000, // 11:00
      );
      expect(
        shouldOfferUpNext(
          segments: [earlyCredits],
          position: const Duration(minutes: 10, seconds: 30),
          duration: duration,
        ),
        isTrue,
      );
    });

    group('fallback window (no credits segment detected)', () {
      test('is false outside the last 60 seconds', () {
        expect(
          shouldOfferUpNext(
            segments: const [],
            position: const Duration(minutes: 43, seconds: 59),
            duration: duration,
          ),
          isFalse,
        );
      });

      test('is true within the last 60 seconds', () {
        expect(
          shouldOfferUpNext(
            segments: const [],
            position: const Duration(minutes: 44),
            duration: duration,
          ),
          isTrue,
        );
      });

      test('is false for zero duration', () {
        expect(
          shouldOfferUpNext(
            segments: const [],
            position: Duration.zero,
            duration: Duration.zero,
          ),
          isFalse,
        );
      });
    });

    test('ignores a non-credits segment (e.g. intro) for the fallback', () {
      const intro = MediaSegment(
        type: SegmentType.intro,
        startMs: 0,
        endMs: 60000,
      );

      expect(
        shouldOfferUpNext(
          segments: [intro],
          position: const Duration(minutes: 44),
          duration: duration,
        ),
        isTrue,
        reason: 'no credits segment was detected, so the fallback window '
            'still applies',
      );
      expect(
        shouldOfferUpNext(
          segments: [intro],
          position: const Duration(minutes: 40),
          duration: duration,
        ),
        isFalse,
        reason: '40:00 is outside the fallback window on a 45-minute '
            'episode, unlike the old 90% heuristic',
      );
    });
  });

  group('UpNextTarget', () {
    const target = UpNextTarget(
      episodeId: 'ep-8',
      fileId: 'file-8',
      seasonNumber: 1,
      episodeNumber: 8,
      title: 'Narkina 5',
    );

    test('builds the episode code from season and episode numbers', () {
      expect(target.episodeCode, 'S1E8');
    });

    test('reads "Next up" in-season and "Next season" when crossing', () {
      expect(target.eyebrow, 'Next up');
      expect(
        const UpNextTarget(
          episodeId: 'ep-1',
          fileId: 'file-1',
          seasonNumber: 2,
          episodeNumber: 1,
          title: 'Premiere',
          crossesSeason: true,
        ).eyebrow,
        'Next season',
      );
    });

    test('joins eyebrow and code with a middle dot for the pill', () {
      expect(target.pillLabel, 'Next up · S1E8');
    });
  });

  group('resolveInSeasonNext', () {
    const withFile = UpNextCandidate(
      id: 'ep-8',
      seasonNumber: 1,
      episodeNumber: 8,
      title: 'Narkina 5',
      fileIds: ['file-8'],
      thumbnailUrl: 'https://example.test/8.jpg',
    );
    const noFile = UpNextCandidate(
      id: 'ep-9',
      seasonNumber: 1,
      episodeNumber: 9,
      title: 'Nobody Is Listening',
      fileIds: [],
    );
    const current = UpNextCandidate(
      id: 'ep-7',
      seasonNumber: 1,
      episodeNumber: 7,
      title: 'Announcement',
      fileIds: ['file-7'],
    );

    test('returns the following episode with its first file', () {
      final target = resolveInSeasonNext([current, withFile], 0);
      expect(target, isNotNull);
      expect(target!.episodeId, 'ep-8');
      expect(target.fileId, 'file-8');
      expect(target.thumbnailUrl, 'https://example.test/8.jpg');
      expect(target.crossesSeason, isFalse);
    });

    test('returns null when the following episode has no file', () {
      // The defect this closes: the prompt used to appear here, count all
      // the way down, and then play nothing at all.
      expect(resolveInSeasonNext([current, noFile], 0), isNull);
    });

    test('returns null at the end of the season', () {
      expect(resolveInSeasonNext([current, withFile], 1), isNull);
    });

    test('returns null for an out-of-range index', () {
      expect(resolveInSeasonNext([current], -1), isNull);
      expect(resolveInSeasonNext(const [], 0), isNull);
    });
  });

  group('resolveSeasonPremiere', () {
    const special = UpNextCandidate(
      id: 'ep-sp',
      seasonNumber: 2,
      episodeNumber: 0,
      title: 'Recap',
      fileIds: ['file-sp'],
    );
    const premiere = UpNextCandidate(
      id: 'ep-201',
      seasonNumber: 2,
      episodeNumber: 1,
      title: 'One Year Later',
      fileIds: ['file-201'],
    );

    test('marks the result as crossing a season', () {
      final target = resolveSeasonPremiere([premiere]);
      expect(target!.crossesSeason, isTrue);
      expect(target.episodeCode, 'S2E1');
      expect(target.eyebrow, 'Next season');
    });

    test('never mistakes a special numbered 0 for the premiere', () {
      final target = resolveSeasonPremiere([special, premiere]);
      expect(target!.episodeId, 'ep-201');
    });

    test('takes the lowest episode number at or above 1', () {
      const second = UpNextCandidate(
        id: 'ep-202',
        seasonNumber: 2,
        episodeNumber: 2,
        title: 'Second',
        fileIds: ['file-202'],
      );
      final target = resolveSeasonPremiere([second, premiere]);
      expect(target!.episodeId, 'ep-201');
    });

    test('returns null when the premiere has no file', () {
      const fileless = UpNextCandidate(
        id: 'ep-201',
        seasonNumber: 2,
        episodeNumber: 1,
        title: 'One Year Later',
        fileIds: [],
      );
      expect(resolveSeasonPremiere([fileless]), isNull);
    });

    test('returns null for an empty season', () {
      expect(resolveSeasonPremiere(const []), isNull);
    });

    test('returns null when the season holds only specials', () {
      expect(resolveSeasonPremiere([special]), isNull);
    });
  });

  group('season crossing end to end', () {
    const finale = UpNextCandidate(
      id: 'ep-112',
      seasonNumber: 1,
      episodeNumber: 12,
      title: 'Rix Road',
      fileIds: ['file-112'],
    );
    const premiere = UpNextCandidate(
      id: 'ep-201',
      seasonNumber: 2,
      episodeNumber: 1,
      title: 'One Year Later',
      fileIds: ['file-201'],
      thumbnailUrl: 'https://example.test/201.jpg',
    );

    test('a finale has no in-season next but does have a premiere', () {
      expect(resolveInSeasonNext([finale], 0), isNull);

      final crossing = resolveSeasonPremiere([premiere]);
      expect(crossing, isNotNull);
      expect(crossing!.seasonNumber, 2);
      expect(crossing.pillLabel, 'Next season · S2E1');
      expect(crossing.thumbnailUrl, 'https://example.test/201.jpg');
    });

    test('the route title uses the target season, not the current one', () {
      // The bug this guards: `_navigateToEpisode` used to hardcode
      // `widget.seasonNumber`, so the premiere would load believing it was
      // still in season 1 and up-next would be dead for all of season 2.
      final crossing = resolveSeasonPremiere([premiere])!;
      expect(crossing.routeTitle, 'S2E1 - One Year Later');
      expect(crossing.seasonNumber, isNot(finale.seasonNumber));
    });
  });
}
