import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/subtitle_candidate.dart';
import 'package:player/domain/models/subtitle_track.dart';
import 'package:player/presentation/widgets/subtitle_track_selector.dart';

const _existing = SubtitleTrack(
  id: 'uuid-1',
  language: 'eng',
  title: 'English',
  format: 'vtt',
  embedded: false,
  content: 'WEBVTT\n',
);

const _candidate = SubtitleCandidate(
  token: 'signed-token',
  language: 'en',
  releaseName: 'Movie.2020.1080p.BluRay.srt',
  format: 'srt',
  rating: 8.5,
  downloadCount: 4200,
  hearingImpaired: false,
  hashMatch: true,
  score: 180,
  providerName: 'Mydia Relay',
);

const _hiCandidate = SubtitleCandidate(
  token: 'hi-token',
  language: 'es',
  releaseName: 'Movie.2020.HI.srt',
  format: 'srt',
  hearingImpaired: true,
  hashMatch: false,
  score: 90,
  providerName: 'OpenSubtitles',
);

const _quotaProvider = SubtitleProviderStatus(
  name: 'OpenSubtitles',
  quotaRemaining: 42,
  quotaTotal: 50,
);

const _downloaded = SubtitleTrack(
  id: 'uuid-new',
  language: 'en',
  title: 'English (External)',
  format: 'srt',
  embedded: false,
  content: 'WEBVTT\n',
);

Widget _host({
  required Future<SubtitleSearchOutcome> Function(List<String>) onSearch,
  required Future<SubtitleTrack> Function(SubtitleCandidate) onDownload,
  ValueChanged<SubtitleTrackSelection>? capture,
}) {
  return MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () async {
            final result = await showSubtitleTrackSelector(
              context,
              const [_existing],
              null,
              onSearch: onSearch,
              onDownload: onDownload,
            );
            capture?.call(result);
          },
          child: const Text('open'),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('lists existing tracks and a search entry', (tester) async {
    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Off'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Search online'), findsOneWidget);
  });

  testWidgets('tapping Off returns SubtitleTrackOff, not a cancellation',
      (tester) async {
    SubtitleTrackSelection? result;

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
      capture: (r) => result = r,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Off'));
    await tester.pumpAndSettle();

    expect(result, isA<SubtitleTrackOff>());
    expect(result, isNot(isA<SubtitleTrackSelectionCancelled>()));
  });

  testWidgets(
      'dismissing the sheet with a barrier tap returns a cancellation, '
      'not Off', (tester) async {
    SubtitleTrackSelection? result;

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
      capture: (r) => result = r,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Tapping outside the sheet, on the modal barrier, is how a real
    // viewer dismisses it without picking anything. The sheet is anchored
    // to the bottom of the screen, so the top-left corner is reliably clear
    // of it and lands on the barrier instead.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    expect(result, isA<SubtitleTrackSelectionCancelled>());
    expect(result, isNot(isA<SubtitleTrackOff>()));
  });

  testWidgets('tapping an existing track returns it wrapped in a pick',
      (tester) async {
    SubtitleTrackSelection? result;

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
      capture: (r) => result = r,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('English'));
    await tester.pumpAndSettle();

    expect(result, isA<SubtitleTrackPicked>());
    expect((result as SubtitleTrackPicked).track.id, 'uuid-1');
  });

  testWidgets('shows results after searching', (tester) async {
    await tester.pumpWidget(_host(
      onSearch: (_) async => const SubtitleSearchOutcome(
        results: [_candidate],
        providers: [SubtitleProviderStatus(name: 'Mydia Relay')],
      ),
      onDownload: (_) async => _downloaded,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();

    expect(find.text('Movie.2020.1080p.BluRay.srt'), findsOneWidget);
    expect(find.text('Exact match'), findsOneWidget);
    expect(find.text('8.5'), findsOneWidget);
  });

  testWidgets('reports an empty result set', (tester) async {
    await tester.pumpWidget(_host(
      onSearch: (_) async => const SubtitleSearchOutcome(
        results: [],
        providers: [SubtitleProviderStatus(name: 'Mydia Relay')],
      ),
      onDownload: (_) async => _downloaded,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();

    expect(find.textContaining('No subtitles found'), findsOneWidget);
  });

  testWidgets('surfaces a provider error', (tester) async {
    await tester.pumpWidget(_host(
      onSearch: (_) async => const SubtitleSearchOutcome(
        results: [],
        providers: [
          SubtitleProviderStatus(
            name: 'Mydia Relay',
            error: 'Daily quota exhausted',
          ),
        ],
      ),
      onDownload: (_) async => _downloaded,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Daily quota exhausted'), findsOneWidget);
  });

  testWidgets('shows provider quota and a hearing-impaired marker',
      (tester) async {
    await tester.pumpWidget(_host(
      onSearch: (_) async => const SubtitleSearchOutcome(
        results: [_hiCandidate],
        providers: [_quotaProvider],
      ),
      onDownload: (_) async => _downloaded,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();

    expect(find.textContaining('42 of 50 left today'), findsOneWidget);
    expect(find.byIcon(Icons.hearing), findsOneWidget);
  });

  testWidgets('shows searching progress before results arrive', (tester) async {
    final completer = Completer<SubtitleSearchOutcome>();

    await tester.pumpWidget(_host(
      onSearch: (_) => completer.future,
      onDownload: (_) async => _downloaded,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pump();

    // The search has not resolved yet: the sheet must show that it is
    // working rather than sitting blank or still showing the track list.
    expect(find.text('Searching for subtitles...'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Movie.2020.1080p.BluRay.srt'), findsNothing);

    completer.complete(const SubtitleSearchOutcome(
      results: [_candidate],
      providers: [SubtitleProviderStatus(name: 'Mydia Relay')],
    ));
    await tester.pumpAndSettle();

    expect(find.text('Movie.2020.1080p.BluRay.srt'), findsOneWidget);
  });

  testWidgets('shows downloading progress before the sheet closes',
      (tester) async {
    final completer = Completer<SubtitleTrack>();
    SubtitleTrackSelection? result;

    await tester.pumpWidget(_host(
      onSearch: (_) async => const SubtitleSearchOutcome(
        results: [_candidate],
        providers: [SubtitleProviderStatus(name: 'Mydia Relay')],
      ),
      onDownload: (_) => completer.future,
      capture: (r) => result = r,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movie.2020.1080p.BluRay.srt'));
    await tester.pump();

    // The download has not resolved yet: closing early would return
    // nothing meaningful, and re-tapping is exactly what a blank screen
    // invites.
    expect(find.text('Downloading subtitle...'), findsOneWidget);
    expect(result, isNull);

    completer.complete(_downloaded);
    await tester.pumpAndSettle();

    expect(result, isA<SubtitleTrackPicked>());
  });

  testWidgets('returns the downloaded track when a result is tapped',
      (tester) async {
    SubtitleTrackSelection? result;

    await tester.pumpWidget(_host(
      onSearch: (_) async => const SubtitleSearchOutcome(
        results: [_candidate],
        providers: [SubtitleProviderStatus(name: 'Mydia Relay')],
      ),
      onDownload: (_) async => _downloaded,
      capture: (r) => result = r,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movie.2020.1080p.BluRay.srt'));
    await tester.pumpAndSettle();

    expect(result, isA<SubtitleTrackPicked>());
    expect((result as SubtitleTrackPicked).track.id, 'uuid-new');
  });

  testWidgets('surfaces a search exception as an error message',
      (tester) async {
    await tester.pumpWidget(_host(
      onSearch: (_) async => throw Exception('relay unreachable'),
      onDownload: (_) async => _downloaded,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();

    expect(find.textContaining('relay unreachable'), findsOneWidget);
  });

  testWidgets(
      'surfaces a download exception as an error message without closing '
      'the sheet', (tester) async {
    SubtitleTrackSelection? result;

    await tester.pumpWidget(_host(
      onSearch: (_) async => const SubtitleSearchOutcome(
        results: [_candidate],
        providers: [SubtitleProviderStatus(name: 'Mydia Relay')],
      ),
      onDownload: (_) async => throw Exception('download failed'),
      capture: (r) => result = r,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movie.2020.1080p.BluRay.srt'));
    await tester.pumpAndSettle();

    expect(find.textContaining('download failed'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets(
      'adjusting a language chip re-runs the search with the updated '
      'languages', (tester) async {
    final calls = <List<String>>[];

    await tester.pumpWidget(_host(
      onSearch: (languages) async {
        calls.add(languages);
        return const SubtitleSearchOutcome(results: [], providers: []);
      },
      onDownload: (_) async => _downloaded,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();

    expect(calls, hasLength(1));

    await tester.tap(find.byKey(const ValueKey('language-chip-es')));
    await tester.pumpAndSettle();

    expect(calls, hasLength(2));
    expect(calls[1], contains('es'));
    expect(calls[1], isNot(equals(calls[0])));
  });
}
