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

    testWidgets(
        'shows the loud glyph at exactly half volume — the <50 vs '
        '>=50 seam', (tester) async {
      await tester.pumpWidget(
        _host(
          VolumeSurface(
            volume: 50,
            onVolumeChanged: (_) {},
            onToggleMute: () {},
          ),
        ),
      );

      expect(
        tester.widget<ControlButton>(find.byKey(VolumeSurface.muteKey)).icon,
        Icons.volume_up_rounded,
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

    testWidgets(
        'dragging the slider fully right reports volume on the 0-100 '
        'scale, not the raw 0-1 slider fraction', (tester) async {
      double? received;
      await tester.pumpWidget(
        _host(
          VolumeSurface(
            volume: 50,
            onVolumeChanged: (v) => received = v,
            onToggleMute: () {},
          ),
        ),
      );

      final sliderFinder = find.descendant(
        of: find.byKey(VolumeSurface.sliderKey),
        matching: find.byType(Slider),
      );

      // A drag far larger than the track saturates at the slider's max
      // (1.0), so this pins down the multiplier regardless of exactly
      // where the thumb starts: if `onVolumeChanged` still multiplied by
      // anything other than 100 (e.g. forgot the conversion and passed
      // the raw 0-1 fraction, or used the wrong constant), this would
      // report 1 (or some other wrong value) instead of 100.
      await tester.drag(sliderFinder, const Offset(1000, 0));
      await tester.pump();

      expect(received, isNotNull);
      expect(received!, closeTo(100.0, 0.5));
    });

    testWidgets(
        'dragging the slider fully left reports 0, not a residual '
        'fraction', (tester) async {
      double? received;
      await tester.pumpWidget(
        _host(
          VolumeSurface(
            volume: 50,
            onVolumeChanged: (v) => received = v,
            onToggleMute: () {},
          ),
        ),
      );

      final sliderFinder = find.descendant(
        of: find.byKey(VolumeSurface.sliderKey),
        matching: find.byType(Slider),
      );

      await tester.drag(sliderFinder, const Offset(-1000, 0));
      await tester.pump();

      expect(received, isNotNull);
      expect(received!, closeTo(0.0, 0.5));
    });

    testWidgets(
        'a volume above 100 clamps the slider to its max instead of '
        'throwing', (tester) async {
      await tester.pumpWidget(
        _host(
          VolumeSurface(
            volume: 150,
            onVolumeChanged: (_) {},
            onToggleMute: () {},
          ),
        ),
      );

      final slider = tester.widget<Slider>(
        find.descendant(
          of: find.byKey(VolumeSurface.sliderKey),
          matching: find.byType(Slider),
        ),
      );
      expect(slider.value, 1.0);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'a negative volume clamps the slider to its min instead of '
        'throwing', (tester) async {
      await tester.pumpWidget(
        _host(
          VolumeSurface(
            volume: -20,
            onVolumeChanged: (_) {},
            onToggleMute: () {},
          ),
        ),
      );

      final slider = tester.widget<Slider>(
        find.descendant(
          of: find.byKey(VolumeSurface.sliderKey),
          matching: find.byType(Slider),
        ),
      );
      expect(slider.value, 0.0);
      expect(tester.takeException(), isNull);
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

    testWidgets('shows the enter-fullscreen glyph when not fullscreen',
        (tester) async {
      await tester.pumpWidget(
        _host(SecondaryCluster(onFullscreenTap: () {})),
      );

      expect(
        tester
            .widget<ControlButton>(find.byKey(SecondaryCluster.fullscreenKey))
            .icon,
        Icons.fullscreen_rounded,
      );
    });

    testWidgets(
        'subtitles, audio, quality, and fullscreen stay left-to-right '
        'ordered with uniform gaps of SecondaryCluster.gap', (tester) async {
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

      // Not strict `lessThan`: `SecondaryCluster.gap` was trimmed to 0 to
      // help close a real `ChromePanel` overflow (see the constant's own
      // dartdoc and `chrome_panel_overflow_test.dart`), so adjacent buttons
      // may legitimately share an edge rather than have a visible gap.
      expect(subtitlesRect.right, lessThanOrEqualTo(audioRect.left));
      expect(audioRect.right, lessThanOrEqualTo(qualityRect.left));
      expect(qualityRect.right, lessThanOrEqualTo(fullscreenRect.left));

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
