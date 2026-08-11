import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/domain/models/media_stream.dart';
import 'package:player/presentation/widgets/media_info/media_info_sheet.dart';

import '../../../test_utils/text_decoration.dart';

const _file = MediaFileInfo(
  id: 'f1',
  fileName: 'Movie.2160p.mkv',
  directory: '/media/movies/Movie (2024)',
  container: 'mkv',
  sizeBytes: 58200000000,
  resolution: '2160p',
  codec: 'hevc',
  streams: [
    MediaStream(index: 0, type: MediaStreamType.video, codec: 'hevc'),
    MediaStream(
      index: 1,
      type: MediaStreamType.audio,
      codec: 'eac3',
      language: 'eng',
      channels: 6,
      channelLayout: '5.1',
      isDefault: true,
    ),
    MediaStream(
      index: 2,
      type: MediaStreamType.subtitle,
      codec: 'subrip',
      language: 'spa',
    ),
  ],
);

const _secondFile = MediaFileInfo(
  id: 'f2',
  fileName: 'Movie.1080p.mkv',
  resolution: '1080p',
  codec: 'h264',
  streams: [MediaStream(index: 0, type: MediaStreamType.video, codec: 'h264')],
);

/// Pushes the panel the way production does: through [showGeneralDialog],
/// whose page has no [Material] ancestor of its own.
///
/// The sibling media-info tests pump the panel inside a [Scaffold], which
/// supplies a Material the real app never provides. That is precisely why they
/// cannot see this class of bug, so this harness must not add one.
Future<void> _openDialog(WidgetTester tester, List<MediaFileInfo> files) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showGeneralDialog<void>(
            context: context,
            barrierDismissible: true,
            barrierLabel: 'Media Info',
            pageBuilder: (_, __, ___) => Align(
              alignment: Alignment.centerRight,
              child: MediaInfoPanel(files: files),
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );

  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void _setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('renders no debug text decorations outside a Scaffold',
      (tester) async {
    _setViewport(tester, const Size(1280, 900));

    await _openDialog(tester, const [_file]);

    expect(find.text('Media Info'), findsOneWidget);
    expectNoDebugTextDecorations(tester);
  });

  testWidgets('opens with multiple versions without a Material assert',
      (tester) async {
    _setViewport(tester, const Size(1280, 900));

    await _openDialog(tester, const [_file, _secondFile]);

    expect(find.byKey(const Key('media-info-version-1')), findsOneWidget);
    expectNoDebugTextDecorations(tester);
  });

  testWidgets('side panel width scales with the viewport', (tester) async {
    _setViewport(tester, const Size(1280, 900));

    await _openDialog(tester, const [_file]);

    expect(
      tester.getSize(find.byKey(const Key('media-info-side'))).width,
      512,
    );
  });

  testWidgets('side panel never drops below the 420 it shipped with',
      (tester) async {
    _setViewport(tester, const Size(900, 800));

    await _openDialog(tester, const [_file]);

    expect(
      tester.getSize(find.byKey(const Key('media-info-side'))).width,
      420,
    );
  });
}
