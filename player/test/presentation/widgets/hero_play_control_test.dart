import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/media_file.dart';
import 'package:player/presentation/widgets/hero_play_control.dart';
import 'package:player/presentation/widgets/play_button.dart';

const _files = [
  MediaFile(id: 'f1', resolution: '1080p', directPlaySupported: true),
];

const _twoFiles = [
  MediaFile(id: 'f1', resolution: '1080p', directPlaySupported: true),
  MediaFile(id: 'f2', resolution: '720p', directPlaySupported: true),
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
    // control lands against the parent's right edge. Asserted against the
    // host's own right edge rather than a hard-coded surface width, so this
    // expresses "flush with the host" instead of a coordinate that merely
    // happens to match it.
    await tester.pumpWidget(_host(
      HeroPlayControl(files: _files, onFileSelected: (_) {}),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byType(HeroPlayControl)).right,
      closeTo(tester.getRect(find.byType(Scaffold)).right, 0.5),
    );
  });

  testWidgets('stays flush right when a quality dropdown is present (2+ files)',
      (tester) async {
    // With 2+ files, SmartPlayButton renders a quality dropdown that becomes
    // the rightmost child instead of PlayButton, so this asserts on the
    // control's own edge rather than PlayButton's — the two are not
    // interchangeable once the dropdown exists.
    await tester.pumpWidget(_host(
      HeroPlayControl(files: _twoFiles, onFileSelected: (_) {}),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(
      tester.getRect(find.byType(HeroPlayControl)).right,
      closeTo(tester.getRect(find.byType(Scaffold)).right, 0.5),
    );
  });
}
