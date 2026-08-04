import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/domain/models/show_next_up.dart';
import 'package:player/presentation/widgets/smart_play_button.dart';

MediaFile _file(String id, String resolution) => MediaFile(
      id: id,
      resolution: resolution,
      directPlaySupported: true,
    );

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

    testWidgets('wide layout shows the full label', (tester) async {
      await tester.pumpWidget(_host(
        SmartPlayButton(
          files: files,
          state: NextUpState.continueWatching,
          cueLine: 'S02E05 · 1080p · 35 min left',
          onFileSelected: (_) {},
        ),
        600,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Continue Watching'), findsOneWidget);
      expect(find.text('S02E05 · 1080p · 35 min left'), findsOneWidget);
    });

    testWidgets('narrow layout drops the label but keeps the cue',
        (tester) async {
      await tester.pumpWidget(_host(
        SmartPlayButton(
          files: files,
          state: NextUpState.continueWatching,
          cueLine: 'S02E05 · 1080p · 35 min left',
          onFileSelected: (_) {},
        ),
        200,
      ));
      await tester.pumpAndSettle();

      expect(find.text('Continue Watching'), findsNothing);
      expect(find.text('S02E05 · 1080p · 35 min left'), findsOneWidget);
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

    testWidgets('tapping reports the selected file', (tester) async {
      MediaFile? picked;
      await tester.pumpWidget(_host(
        SmartPlayButton(
          files: files,
          state: NextUpState.start,
          cueLine: 'S01E01 · 1080p',
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
