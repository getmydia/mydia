import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/domain/models/audio_track.dart';
import 'package:player/presentation/widgets/audio_track_selector.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

import '../../test_utils/osd_contrast.dart';

const _english = AudioTrack(
  id: 'a1',
  language: 'eng',
  title: 'English',
  isDefault: true,
);
const _commentary = AudioTrack(id: 'a2', language: 'eng', title: 'Commentary');

Future<void> _open(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAudioTrackSelector(
              context,
              const [_english, _commentary],
              _english,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('opens on the OSD material', (tester) async {
    await _open(tester);

    expect(
      find.ancestor(
        of: find.text('Audio Tracks'),
        matching: find.byType(GlassSurface),
      ),
      findsOneWidget,
    );
  });

  testWidgets('marks the current track in the accent colour', (tester) async {
    await _open(tester);

    final check = tester.widget<Icon>(find.byIcon(Icons.check));
    expect(check.color, AppColors.primary);
  });

  testWidgets('every glyph holds 4.5:1 on the OSD material', (tester) async {
    await _open(tester);

    final colors =
        osdParagraphColors(tester, find.byType(AudioTrackSelectorSheet));
    expect(colors, isNotEmpty);
    for (final color in colors) {
      expect(osdContrast(color), greaterThanOrEqualTo(4.5), reason: '$color');
    }
  });
}
