import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/presentation/widgets/hero_play_control.dart';
import 'package:player/presentation/widgets/play_button.dart';

const _files = [
  MediaFile(id: 'f1', resolution: '1080p', directPlaySupported: true),
];

/// Mirrors how both detail heroes embed the control: a Row whose leading child
/// is Expanded (the title column) and whose trailing child is non-flex.
Widget _host(Widget control) => MaterialApp(
      home: Scaffold(
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            const Expanded(child: Text('Some Title')),
            const SizedBox(width: 16),
            control,
          ],
        ),
      ),
    );

void main() {
  testWidgets('renders the Play label beside a play button', (tester) async {
    await tester.pumpWidget(_host(
      HeroPlayControl(files: _files, onFileSelected: (_) {}),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Play'), findsOneWidget);
    expect(find.byType(PlayButton), findsOneWidget);
  });

  testWidgets('tapping reports the auto-selected file', (tester) async {
    MediaFile? picked;
    await tester.pumpWidget(_host(
      HeroPlayControl(files: _files, onFileSelected: (f) => picked = f),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byType(PlayButton));
    await tester.pumpAndSettle();

    expect(picked?.id, 'f1');
  });

  testWidgets('as a non-flex trailing Row child it sits flush right',
      (tester) async {
    // This is the property the whole placement fix rests on: a non-flex Row
    // child takes its intrinsic width, so Expanded absorbs the slack and the
    // control lands against the parent's right edge.
    await tester.pumpWidget(_host(
      HeroPlayControl(files: _files, onFileSelected: (_) {}),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    // Default test surface is 800x600. With a single file SmartPlayButton
    // renders no quality dropdown, so PlayButton is the control's last child
    // and its right edge is the control's right edge.
    expect(tester.getRect(find.byType(PlayButton)).right, closeTo(800, 0.5));
  });
}
