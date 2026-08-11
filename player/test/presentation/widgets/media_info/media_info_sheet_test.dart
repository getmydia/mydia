import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/media_stream.dart';
import 'package:player/presentation/widgets/media_info/media_info_sheet.dart';

const _file = MediaFileInfo(
  id: 'f1',
  fileName: 'Movie.2160p.mkv',
  resolution: '2160p',
  codec: 'hevc',
  streams: [
    MediaStream(index: 0, type: MediaStreamType.video, codec: 'hevc'),
  ],
);

Widget _harness(Size size) {
  return MediaQuery(
    data: MediaQueryData(size: size),
    child: const MaterialApp(
      home: Scaffold(
        body: MediaInfoPanel(files: [_file]),
      ),
    ),
  );
}

void main() {
  testWidgets('lays out as a bottom sheet below the desktop breakpoint',
      (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(const Size(390, 844)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('media-info-bottom')), findsOneWidget);
    expect(find.byKey(const Key('media-info-side')), findsNothing);
  });

  testWidgets('lays out as a side panel at or above the desktop breakpoint',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(const Size(1280, 800)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('media-info-side')), findsOneWidget);
    expect(find.byKey(const Key('media-info-bottom')), findsNothing);
  });

  testWidgets('keeps the selected version across a rebuild', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(const Size(390, 844)));
    await tester.pumpAndSettle();

    expect(find.text('Movie.2160p.mkv'), findsOneWidget);
  });
}
