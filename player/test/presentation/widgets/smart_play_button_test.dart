import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/domain/models/progress.dart';
import 'package:player/domain/models/show_next_up.dart';
import 'package:player/presentation/widgets/smart_play_button.dart';

MediaFile _file(String id, String resolution) => MediaFile(
      id: id,
      resolution: resolution,
      directPlaySupported: true,
    );

/// Half-watched S02E05: 2700 - 600 seconds left, i.e. "35 min left".
const _partlyWatched = NextUpEpisode(
  id: 'e1',
  seasonNumber: 2,
  episodeNumber: 5,
  progress: Progress(
    positionSeconds: 600,
    durationSeconds: 2700,
    percentage: 22.2,
    watched: false,
  ),
);

const _unwatched = NextUpEpisode(id: 'e2', seasonNumber: 1, episodeNumber: 1);

Widget _host(Widget child, double width) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(width: width, child: child),
        ),
      ),
    );

void main() {
  group('SmartPlayButton', () {
    testWidgets('preserves selected file when files list becomes empty',
        (tester) async {
      final file = _file('a', '480p');
      var files = [file];

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SmartPlayButton(
              files: files,
              onFileSelected: (_) {},
            ),
          ),
        ),
      );

      // Let the widget settle and detect the best file
      await tester.pumpAndSettle();

      // Verify the file is selected (resolution label is visible)
      expect(find.text('480p'), findsOneWidget);

      // Rebuild with an empty files list
      files = [];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SmartPlayButton(
              files: files,
              onFileSelected: (_) {},
            ),
          ),
        ),
      );

      // Let the widget process the update
      await tester.pumpAndSettle();

      // The previously selected file should still be reflected in the UI
      // (resolution label should still be present, state not cleared)
      expect(find.text('480p'), findsOneWidget);
    });

    final files = [
      const MediaFile(id: 'f1', resolution: '1080p', directPlaySupported: true),
    ];

    testWidgets(
        'wide layout shows the full label and a cue line naming the '
        'resolution of the file it picked', (tester) async {
      await tester.pumpWidget(_host(
        SmartPlayButton(
          files: files,
          state: NextUpState.continueWatching,
          episode: _partlyWatched,
          onFileSelected: (_) {},
        ),
        600,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Continue Watching'), findsOneWidget);
      // The resolution comes from the selected MediaFile, not from the
      // caller: the pill form prints no quality label of its own, so if the
      // widget stopped feeding its selection into the cue line the quality
      // would vanish from the hero entirely.
      expect(find.text('S02E05 · 1080p · 35 min left'), findsOneWidget);
    });

    testWidgets(
        'narrow layout drops the label but keeps the cue, '
        'prefixed with the state word', (tester) async {
      await tester.pumpWidget(_host(
        SmartPlayButton(
          files: files,
          state: NextUpState.continueWatching,
          episode: _partlyWatched,
          onFileSelected: (_) {},
        ),
        200,
      ));
      await tester.pumpAndSettle();

      // The full pill label is gone. Without the "min left" suffix (which
      // only nextUpCueLine's continueWatching branch adds), a bare cue like
      // "S01E01" cannot distinguish resume/next/start on its own, so the
      // short state word restores that distinction once the pill label is
      // dropped. The resolution moves out of the cue line here because the
      // icon form prints it beside the play circle.
      expect(find.text('Continue Watching'), findsNothing);
      expect(find.text('1080p'), findsOneWidget);
      expect(
        find.text('Continue · S02E05 · 35 min left'),
        findsOneWidget,
      );
    });

    testWidgets('without a state it renders the plain icon form',
        (tester) async {
      await tester.pumpWidget(_host(
        SmartPlayButton(files: files, onFileSelected: (_) {}),
        600,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Continue Watching'), findsNothing);
      expect(find.text('1080p'), findsOneWidget);
    });

    testWidgets('a state without an episode renders the pill with no cue line',
        (tester) async {
      await tester.pumpWidget(_host(
        SmartPlayButton(
          files: files,
          state: NextUpState.start,
          onFileSelected: (_) {},
        ),
        600,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Start Watching'), findsOneWidget);
      expect(find.textContaining('S0'), findsNothing);
    });

    testWidgets(
        'collapses to the icon form without overflow inside a real Row '
        'embedding (Expanded metadata sibling + Flexible-wrapped button)',
        (tester) async {
      // Reproduces how the show detail hero actually embeds this widget: a
      // Row whose other child is Expanded (the title/metadata column) and
      // whose SmartPlayButton is wrapped in Flexible. A bare (non-flex)
      // trailing Row child gets UNBOUNDED main-axis constraints from Flutter,
      // so SmartPlayButton's internal LayoutBuilder would see an effectively
      // infinite maxWidth, "compact" would never trigger, and the full-width
      // pill would overflow the narrow box below. Flexible is what gives the
      // LayoutBuilder a bounded, real maxWidth to collapse against.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 340,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Expanded(child: Text('Show Title')),
                    const SizedBox(width: 12),
                    Flexible(
                      child: SmartPlayButton(
                        files: files,
                        state: NextUpState.continueWatching,
                        episode: _partlyWatched,
                        onFileSelected: (_) {},
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // No RenderFlex overflow was thrown during layout.
      expect(tester.takeException(), isNull);
      // The pill collapsed to the icon form: the full label is gone, and the
      // compact cue line (with its state-word prefix) is what remains.
      expect(find.text('Continue Watching'), findsNothing);
      expect(
        find.text('Continue · S02E05 · 35 min left'),
        findsOneWidget,
      );
    });

    testWidgets('tapping reports the selected file', (tester) async {
      MediaFile? picked;
      await tester.pumpWidget(_host(
        SmartPlayButton(
          files: files,
          state: NextUpState.start,
          episode: _unwatched,
          onFileSelected: (f) => picked = f,
        ),
        600,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Start Watching'));
      await tester.pumpAndSettle();

      expect(picked?.id, 'f1');
    });
  });
}
