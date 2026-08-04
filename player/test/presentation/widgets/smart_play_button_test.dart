import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/presentation/widgets/smart_play_button.dart';

MediaFile _file(String id, String resolution) => MediaFile(
      id: id,
      resolution: resolution,
      directPlaySupported: true,
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
  });
}
