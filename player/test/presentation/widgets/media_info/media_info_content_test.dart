import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/media_stream.dart';
import 'package:player/presentation/widgets/media_info/media_info_content.dart';

MediaFileInfo _richFile() => MediaFileInfo(
      id: 'f1',
      fileName: 'Blade.Runner.2049.2160p.mkv',
      directory: '/media/movies/Blade Runner 2049 (2017)',
      container: 'mkv',
      durationSeconds: 9780,
      sizeBytes: 58200000000,
      bitrate: 47300000,
      resolution: '2160p',
      codec: 'hevc',
      streams: const [
        MediaStream(
          index: 0,
          type: MediaStreamType.video,
          codec: 'hevc',
          profile: 'Main 10',
          width: 3840,
          height: 2160,
          frameRate: 23.976,
          bitDepth: 10,
        ),
        MediaStream(
          index: 1,
          type: MediaStreamType.audio,
          codec: 'truehd',
          channels: 8,
          channelLayout: '7.1',
          language: 'eng',
          isDefault: true,
        ),
        MediaStream(
          index: 2,
          type: MediaStreamType.subtitle,
          codec: 'subrip',
          language: 'spa',
          isForced: true,
        ),
      ],
    );

MediaFileInfo _bareFile() => const MediaFileInfo(
      id: 'f2',
      fileName: 'Old.Movie.1080p.mkv',
      resolution: '1080p',
      codec: 'h264',
      sizeBytes: 8400000,
      streams: null,
    );

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders file, video, audio and subtitle sections',
      (tester) async {
    await tester.pumpWidget(_wrap(MediaInfoContent(
      files: [_richFile()],
      selectedIndex: 0,
      onSelectVersion: (_) {},
    )));

    expect(find.text('Blade.Runner.2049.2160p.mkv'), findsOneWidget);
    expect(find.textContaining('54.2 GB'), findsOneWidget);
    expect(find.textContaining('2h 43m'), findsOneWidget);
    expect(find.textContaining('3840'), findsOneWidget);
    expect(find.textContaining('23.976 fps'), findsOneWidget);
    expect(find.textContaining('7.1 (8 ch)'), findsOneWidget);
    expect(find.textContaining('English'), findsOneWidget);
    expect(find.textContaining('Spanish'), findsOneWidget);
  });

  testWidgets('shows the not-yet-captured note when streams are null',
      (tester) async {
    await tester.pumpWidget(_wrap(MediaInfoContent(
      files: [_bareFile()],
      selectedIndex: 0,
      onSelectVersion: (_) {},
    )));

    expect(find.text(kStreamsPendingMessage), findsOneWidget);
    expect(find.textContaining('1080p'), findsWidgets);
  });

  testWidgets('hides the version switcher for a single file', (tester) async {
    await tester.pumpWidget(_wrap(MediaInfoContent(
      files: [_richFile()],
      selectedIndex: 0,
      onSelectVersion: (_) {},
    )));

    expect(find.byKey(const Key('media-info-versions')), findsNothing);
  });

  testWidgets('reports the tapped version', (tester) async {
    var selected = -1;

    await tester.pumpWidget(_wrap(MediaInfoContent(
      files: [_richFile(), _bareFile()],
      selectedIndex: 0,
      onSelectVersion: (index) => selected = index,
    )));

    expect(find.byKey(const Key('media-info-versions')), findsOneWidget);
    await tester.tap(find.byKey(const Key('media-info-version-1')));
    await tester.pumpAndSettle();

    expect(selected, 1);
  });
}
