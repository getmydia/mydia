import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/video_controls/control_button.dart';
import 'package:player/presentation/widgets/video_controls/panel_controls.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(child: SizedBox(width: 600, child: child)),
      ),
    );

void main() {
  group('VolumeSurface', () {
    testWidgets('slider is always visible, not hover-revealed', (tester) async {
      await tester.pumpWidget(
        _host(
          VolumeSurface(
            volume: 60,
            onVolumeChanged: (_) {},
            onToggleMute: () {},
          ),
        ),
      );

      expect(find.byKey(VolumeSurface.sliderKey), findsOneWidget);
      expect(tester.getSize(find.byKey(VolumeSurface.sliderKey)).width,
          greaterThan(0));
    });

    testWidgets('shows a muted glyph at zero volume', (tester) async {
      await tester.pumpWidget(
        _host(
          VolumeSurface(
            volume: 0,
            onVolumeChanged: (_) {},
            onToggleMute: () {},
          ),
        ),
      );

      expect(
        tester.widget<ControlButton>(find.byKey(VolumeSurface.muteKey)).icon,
        Icons.volume_off_rounded,
      );
    });

    testWidgets('shows a low glyph below half volume', (tester) async {
      await tester.pumpWidget(
        _host(
          VolumeSurface(
            volume: 20,
            onVolumeChanged: (_) {},
            onToggleMute: () {},
          ),
        ),
      );

      expect(
        tester.widget<ControlButton>(find.byKey(VolumeSurface.muteKey)).icon,
        Icons.volume_down_rounded,
      );
    });

    testWidgets('mute button fires', (tester) async {
      var toggled = false;
      await tester.pumpWidget(
        _host(
          VolumeSurface(
            volume: 60,
            onVolumeChanged: (_) {},
            onToggleMute: () => toggled = true,
          ),
        ),
      );

      await tester.tap(find.byKey(VolumeSurface.muteKey));
      expect(toggled, isTrue);
    });

    testWidgets(
        'mute button sits immediately left of the slider — geometry, not '
        'just widget presence', (tester) async {
      await tester.pumpWidget(
        _host(
          VolumeSurface(
            volume: 60,
            onVolumeChanged: (_) {},
            onToggleMute: () {},
          ),
        ),
      );

      final muteRect = tester.getRect(find.byKey(VolumeSurface.muteKey));
      final sliderRect = tester.getRect(find.byKey(VolumeSurface.sliderKey));

      expect(muteRect.right, lessThanOrEqualTo(sliderRect.left));
      expect(sliderRect.width, VolumeSurface.sliderWidth);
    });
  });

  group('SecondaryCluster', () {
    testWidgets('disables track buttons when no tracks exist', (tester) async {
      await tester.pumpWidget(
        _host(const SecondaryCluster(onFullscreenTap: null)),
      );

      expect(
        tester
            .widget<ControlButton>(find.byKey(SecondaryCluster.subtitlesKey))
            .enabled,
        isFalse,
      );
      expect(
        tester
            .widget<ControlButton>(find.byKey(SecondaryCluster.audioKey))
            .enabled,
        isFalse,
      );
    });

    testWidgets('enables track buttons when tracks exist', (tester) async {
      await tester.pumpWidget(
        _host(
          SecondaryCluster(
            subtitleTrackCount: 2,
            audioTrackCount: 3,
            onSubtitleTap: () {},
            onAudioTap: () {},
          ),
        ),
      );

      expect(
        tester
            .widget<ControlButton>(find.byKey(SecondaryCluster.subtitlesKey))
            .enabled,
        isTrue,
      );
    });

    testWidgets('omits quality when no callback is supplied', (tester) async {
      await tester.pumpWidget(_host(const SecondaryCluster()));
      expect(find.byKey(SecondaryCluster.qualityKey), findsNothing);
    });

    testWidgets('shows quality when a callback is supplied', (tester) async {
      await tester.pumpWidget(
        _host(SecondaryCluster(onQualityTap: () {})),
      );
      expect(find.byKey(SecondaryCluster.qualityKey), findsOneWidget);
    });

    testWidgets('swaps the fullscreen glyph', (tester) async {
      await tester.pumpWidget(
        _host(SecondaryCluster(isFullscreen: true, onFullscreenTap: () {})),
      );

      expect(
        tester
            .widget<ControlButton>(find.byKey(SecondaryCluster.fullscreenKey))
            .icon,
        Icons.fullscreen_exit_rounded,
      );
    });

    testWidgets(
        'subtitles, audio, quality, and fullscreen stay left-to-right '
        'ordered with uniform 4px gaps', (tester) async {
      await tester.pumpWidget(
        _host(
          SecondaryCluster(
            subtitleTrackCount: 1,
            audioTrackCount: 1,
            onSubtitleTap: () {},
            onAudioTap: () {},
            onQualityTap: () {},
            onFullscreenTap: () {},
          ),
        ),
      );

      final subtitlesRect =
          tester.getRect(find.byKey(SecondaryCluster.subtitlesKey));
      final audioRect = tester.getRect(find.byKey(SecondaryCluster.audioKey));
      final qualityRect =
          tester.getRect(find.byKey(SecondaryCluster.qualityKey));
      final fullscreenRect =
          tester.getRect(find.byKey(SecondaryCluster.fullscreenKey));

      expect(subtitlesRect.right, lessThan(audioRect.left));
      expect(audioRect.right, lessThan(qualityRect.left));
      expect(qualityRect.right, lessThan(fullscreenRect.left));

      expect(
        audioRect.left - subtitlesRect.right,
        closeTo(SecondaryCluster.gap, 0.5),
      );
      expect(
        qualityRect.left - audioRect.right,
        closeTo(SecondaryCluster.gap, 0.5),
      );
      expect(
        fullscreenRect.left - qualityRect.right,
        closeTo(SecondaryCluster.gap, 0.5),
      );
    });
  });
}
