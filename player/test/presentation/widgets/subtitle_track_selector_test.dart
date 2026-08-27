import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_flutter.dart';
import 'package:player/core/player/subtitle_language_prefs.dart';
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
  ValueListenable<int?>? subtitleDelayMs,
  // True by default: most tests in this file that do pass a non-null
  // [subtitleDelayMs] are not about Save gating specifically, and the
  // pre-gating behaviour (Save always offered once a track is selected) is
  // the right default to keep those unaffected.
  bool canSaveDelay = true,
  Future<void> Function(int deltaMs)? onNudgeSubtitleDelay,
  Future<void> Function()? onResetSubtitleDelay,
  Future<void> Function()? onSaveSubtitleDelay,
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
              // Most tests in this file don't exercise the delay row -- that
              // has its own coverage in subtitle_track_loading_test.dart (the
              // pure functions) and player_screen.dart (the wiring). A
              // notifier stuck at null keeps the row hidden by default, and
              // the callbacks are never expected to fire.
              subtitleDelayMs: subtitleDelayMs ?? ValueNotifier<int?>(null),
              canSaveDelay: canSaveDelay,
              onNudgeSubtitleDelay: onNudgeSubtitleDelay ?? (_) async {},
              onResetSubtitleDelay: onResetSubtitleDelay ?? () async {},
              onSaveSubtitleDelay: onSaveSubtitleDelay ?? () async {},
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

  testWidgets(
      'surfaces a search failure with a plain message, not the raw '
      'exception', (tester) async {
    await tester.pumpWidget(_host(
      onSearch: (_) async => throw Exception('relay unreachable'),
      onDownload: (_) async => _downloaded,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();

    // The exception's own text must never reach the viewer: today it is a
    // developer-facing placeholder message, and after Task 16 it will be a
    // GraphQL client's `OperationException` dump.
    expect(find.textContaining('relay unreachable'), findsNothing);
    expect(find.textContaining('Subtitle search failed'), findsOneWidget);
  });

  testWidgets(
      'surfaces a download failure with a plain message, not the raw '
      'exception, and does not close the sheet', (tester) async {
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

    expect(find.textContaining('download failed'), findsNothing);
    expect(find.textContaining('Could not download'), findsOneWidget);
    expect(result, isNull);
  });

  testWidgets(
      'shows a SubtitleActionException message verbatim instead of the '
      'generic download copy', (tester) async {
    await tester.pumpWidget(_host(
      onSearch: (_) async => const SubtitleSearchOutcome(
        results: [_candidate],
        providers: [SubtitleProviderStatus(name: 'Mydia Relay')],
      ),
      onDownload: (_) async => throw const SubtitleActionException(
        'These search results expired. Search again.',
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Movie.2020.1080p.BluRay.srt'));
    await tester.pumpAndSettle();

    // A candidate's token expires after fifteen minutes, and the generic
    // "Could not download that subtitle. Try again." invites re-tapping the
    // same stale token forever. Catches an implementation that renders the
    // fallback for every failure alike.
    expect(
      find.text('These search results expired. Search again.'),
      findsOneWidget,
    );
    expect(find.textContaining('Could not download'), findsNothing);
    // And catches one that reaches for `toString()`, which would prefix the
    // class name onto a line written for a viewer.
    expect(find.textContaining('SubtitleActionException'), findsNothing);
  });

  testWidgets(
      'shows a SubtitleActionException message verbatim instead of the '
      'generic search copy', (tester) async {
    await tester.pumpWidget(_host(
      onSearch: (_) async => throw const SubtitleActionException(
        'Subtitle search needs a connection to your server.',
      ),
      onDownload: (_) async => _downloaded,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();

    expect(
      find.text('Subtitle search needs a connection to your server.'),
      findsOneWidget,
    );
    expect(find.textContaining('Subtitle search failed'), findsNothing);
  });

  testWidgets(
      'adjusting a language chip re-runs the search with a different '
      'language set', (tester) async {
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
    // Asserts the delta rather than assuming 'es' was *added*: under a
    // Spanish test locale it would already be selected by default, and the
    // tap would remove it instead. Either direction, the set must actually
    // change, and specifically on 'es'.
    expect(calls[1].toSet(), isNot(equals(calls[0].toSet())));
    expect(calls[1].contains('es'), isNot(calls[0].contains('es')));
  });

  testWidgets('refuses to deselect the last remaining language',
      (tester) async {
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

    // Strip down to exactly one selected language, deselecting every other
    // one the test's device locale happened to start with, so this test
    // does not assume a specific default list.
    var current = calls.single;
    for (final code in current.skip(1).toList()) {
      await tester.tap(find.byKey(ValueKey('language-chip-$code')));
      await tester.pumpAndSettle();
      current = calls.last;
    }
    expect(current, hasLength(1));
    final callsBeforeLastToggle = calls.length;

    // Attempting to deselect the one remaining language must be refused --
    // otherwise every future search would silently run against nothing.
    await tester.tap(find.byKey(ValueKey('language-chip-${current.single}')));
    await tester.pumpAndSettle();

    expect(calls, hasLength(callsBeforeLastToggle));
  });

  testWidgets(
      'a language outside the curated chip roster still gets a chip and '
      'can be adjusted', (tester) async {
    // Opened with `bytes:`, which puts Hive on its in-memory storage
    // backend: every read and write becomes a completed `Future.value()`
    // with no file touched, and no `Hive.init` path to point anywhere.
    //
    // That is load-bearing, not tidiness. `testWidgets` runs its body in a
    // fake-async zone, and toggling a chip below fires
    // `SubtitleLanguagePrefs.save` -- so a disk-backed box leaves a real
    // file write outstanding that the zone never drives. An earlier version
    // of this test opened one under `Directory.systemTemp` and did exactly
    // that: it hung until the ten minute per-test timeout, and then failed
    // the next two tests in this file with `'!inTest': is not true`,
    // because a test that times out never releases the binding.
    final box = await Hive.openBox<List>(
      SubtitleLanguagePrefs.boxName,
      bytes: Uint8List(0),
    );
    // Written directly, bypassing `save`, to seed a language the curated
    // roster in `subtitle_track_selector.dart` does not include -- the
    // scenario a device locale outside that fixed list produces.
    await box.put('languages', ['th', 'en']);
    // `deleteFromDisk` is unsupported on a memory box and there is nothing
    // on disk to clean up; closing is what unregisters the name so a later
    // test does not inherit this box.
    addTearDown(box.close);

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();

    // 'th' is not in the curated roster (`SubtitleCandidate.languageNames`
    // has no Thai entry), so without unioning the roster with whatever is
    // actually selected, this chip would never render and 'th' could never
    // be seen or removed.
    expect(find.text('TH'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('language-chip-th')));
    await tester.pumpAndSettle();

    expect(find.text('TH'), findsNothing);
  });

  testWidgets('tapping "Back to tracks" returns to the track list',
      (tester) async {
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

    await tester.tap(find.text('Back to tracks'));
    await tester.pumpAndSettle();

    // Back on the track list: "Off" and the existing track are reachable
    // again, and the search result is no longer on screen.
    expect(find.text('Off'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Movie.2020.1080p.BluRay.srt'), findsNothing);
  });

  testWidgets(
      'a second tap on a result while the first download is still in '
      'flight is ignored', (tester) async {
    var downloadCalls = 0;
    final completer = Completer<SubtitleTrack>();

    await tester.pumpWidget(_host(
      onSearch: (_) async => const SubtitleSearchOutcome(
        results: [_candidate],
        providers: [SubtitleProviderStatus(name: 'Mydia Relay')],
      ),
      onDownload: (_) {
        downloadCalls++;
        return completer.future;
      },
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Search online'));
    await tester.pumpAndSettle();

    // Two taps before either has a chance to rebuild the sheet out of
    // `results` mode -- the scenario a fast double-tap produces. `_mode`
    // flips to `downloading` synchronously inside the first tap's
    // `setState`, so the second tap, landing on the same still-rendered
    // tile, must see that and refuse to issue a second download.
    await tester.tap(find.text('Movie.2020.1080p.BluRay.srt'));
    await tester.tap(find.text('Movie.2020.1080p.BluRay.srt'));
    await tester.pump();

    expect(downloadCalls, 1);

    completer.complete(_downloaded);
    await tester.pumpAndSettle();
  });

  testWidgets('hides the delay row when the notifier is null', (tester) async {
    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Subtitle delay'), findsNothing);
  });

  testWidgets(
      'shows the delay row with the current value when the '
      'notifier has one', (tester) async {
    final delay = ValueNotifier<int?>(250);
    addTearDown(delay.dispose);

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
      subtitleDelayMs: delay,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Subtitle delay'), findsOneWidget);
    expect(find.text('+250 ms'), findsOneWidget);
  });

  testWidgets(
      'the delay row updates live when the notifier changes while the '
      'sheet is already open', (tester) async {
    // The sheet is a separate route from whatever owns the notifier, so
    // this is what proves a keyboard nudge (or the initial offsets load)
    // reaches the row without the sheet having to be reopened.
    final delay = ValueNotifier<int?>(0);
    addTearDown(delay.dispose);

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
      subtitleDelayMs: delay,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('+0 ms'), findsOneWidget);

    delay.value = -400;
    await tester.pump();

    expect(find.text('-400 ms'), findsOneWidget);
  });

  testWidgets('the stepper buttons nudge by the documented +/-100ms',
      (tester) async {
    final deltas = <int>[];
    final delay = ValueNotifier<int?>(0);
    addTearDown(delay.dispose);

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
      subtitleDelayMs: delay,
      onNudgeSubtitleDelay: (delta) async => deltas.add(delta),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('subtitle-delay-increment')));
    await tester.tap(find.byKey(const ValueKey('subtitle-delay-decrement')));
    await tester.pump();

    expect(deltas, [100, -100]);
  });

  testWidgets('Reset and Save call their own callbacks', (tester) async {
    var resetCalls = 0;
    var saveCalls = 0;
    final delay = ValueNotifier<int?>(300);
    addTearDown(delay.dispose);

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
      subtitleDelayMs: delay,
      onResetSubtitleDelay: () async => resetCalls++,
      onSaveSubtitleDelay: () async => saveCalls++,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('subtitle-delay-reset')));
    await tester.tap(find.byKey(const ValueKey('subtitle-delay-save')));
    await tester.pump();

    expect(resetCalls, 1);
    expect(saveCalls, 1);
  });

  testWidgets(
      'hides Save but keeps the steppers and Reset when canSaveDelay is '
      'false', (tester) async {
    // Stands in for the sheet having been opened on an mpv-native track:
    // the caller (player_screen.dart) computes canSaveDelay from
    // canSaveSubtitleDelay(currentTrack?.id) and passes false for that
    // case. This test only pins the sheet's own reaction to that flag, not
    // the id-space reasoning behind it -- that lives in
    // subtitle_track_loading_test.dart's canSaveSubtitleDelay coverage.
    final delay = ValueNotifier<int?>(300);
    addTearDown(delay.dispose);

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
      subtitleDelayMs: delay,
      canSaveDelay: false,
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Subtitle delay'), findsOneWidget,
        reason: 'the row itself must still show -- the live delay still '
            'applies for the current session even though it cannot be '
            'saved');
    expect(
        find.byKey(const ValueKey('subtitle-delay-decrement')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('subtitle-delay-increment')), findsOneWidget);
    expect(find.byKey(const ValueKey('subtitle-delay-reset')), findsOneWidget);
    expect(find.byKey(const ValueKey('subtitle-delay-save')), findsNothing,
        reason: 'Save must be absent, not merely disabled -- a control that '
            'reports success and silently does not persist is worse than no '
            'control at all');
  });

  // Regression coverage: the delay row's IconButton/TextButton onPressed
  // fields take a VoidCallback, so a bare `() => onNudge(-100)` discards the
  // Future onNudge/onReset/onSave return. A rejection then escaped as an
  // unhandled exception with no error state anywhere in the sheet. These pin
  // that each action is awaited by a guarded handler that catches the
  // failure and surfaces it instead of letting it escape.
  testWidgets(
      'a rejected nudge surfaces an error instead of an unhandled exception',
      (tester) async {
    final delay = ValueNotifier<int?>(0);
    addTearDown(delay.dispose);

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
      subtitleDelayMs: delay,
      onNudgeSubtitleDelay: (_) async => throw Exception('nudge failed'),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('subtitle-delay-increment')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not adjust'), findsOneWidget);
  });

  testWidgets(
      'a rejected reset surfaces an error instead of an unhandled exception',
      (tester) async {
    final delay = ValueNotifier<int?>(300);
    addTearDown(delay.dispose);

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
      subtitleDelayMs: delay,
      onResetSubtitleDelay: () async => throw Exception('reset failed'),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('subtitle-delay-reset')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not reset'), findsOneWidget);
  });

  testWidgets(
      'a rejected save surfaces an error instead of an unhandled exception',
      (tester) async {
    final delay = ValueNotifier<int?>(300);
    addTearDown(delay.dispose);

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
      subtitleDelayMs: delay,
      onSaveSubtitleDelay: () async => throw Exception('save failed'),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('subtitle-delay-save')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not save'), findsOneWidget);
  });

  testWidgets('a SubtitleActionException from a delay action is shown verbatim',
      (tester) async {
    final delay = ValueNotifier<int?>(0);
    addTearDown(delay.dispose);

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
      subtitleDelayMs: delay,
      onNudgeSubtitleDelay: (_) async => throw const SubtitleActionException(
        'Your session expired. Sign in again.',
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('subtitle-delay-increment')));
    await tester.pumpAndSettle();

    expect(
      find.text('Your session expired. Sign in again.'),
      findsOneWidget,
    );
    expect(find.textContaining('Could not adjust'), findsNothing);
  });

  testWidgets('a successful nudge after a prior failure clears the error',
      (tester) async {
    final delay = ValueNotifier<int?>(0);
    addTearDown(delay.dispose);
    var shouldFail = true;

    await tester.pumpWidget(_host(
      onSearch: (_) async =>
          const SubtitleSearchOutcome(results: [], providers: []),
      onDownload: (_) async => _downloaded,
      subtitleDelayMs: delay,
      onNudgeSubtitleDelay: (_) async {
        if (shouldFail) throw Exception('nudge failed');
      },
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('subtitle-delay-increment')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not adjust'), findsOneWidget);

    shouldFail = false;
    await tester.tap(find.byKey(const ValueKey('subtitle-delay-increment')));
    await tester.pumpAndSettle();

    expect(find.textContaining('Could not adjust'), findsNothing);
  });
}
