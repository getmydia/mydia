import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/window/decoration_layout.dart';

void main() {
  group('parseDecorationLayout', () {
    test('GNOME stock puts close alone on the end side', () {
      final layout = parseDecorationLayout('appmenu:close');
      expect(layout.start, isEmpty);
      expect(layout.end, [WindowButton.close]);
    });

    test('the development machine layout: three buttons on the end side', () {
      final layout = parseDecorationLayout('appmenu:minimize,maximize,close');
      expect(layout.start, isEmpty);
      expect(
        layout.end,
        [WindowButton.minimize, WindowButton.maximize, WindowButton.close],
      );
    });

    test('KDE style leading colon puts everything on the end side', () {
      final layout = parseDecorationLayout(':minimize,maximize,close');
      expect(layout.start, isEmpty);
      expect(
        layout.end,
        [WindowButton.minimize, WindowButton.maximize, WindowButton.close],
      );
    });

    test(
        'a string with NO colon puts every button on the START side, which is '
        'what GTK does via `if (tokens[i] == NULL) break` and is the case '
        'most likely to be got backwards', () {
      final layout = parseDecorationLayout('minimize,maximize,close');
      expect(
        layout.start,
        [WindowButton.minimize, WindowButton.maximize, WindowButton.close],
      );
      expect(layout.end, isEmpty);
    });

    test('a trailing colon leaves the end side empty', () {
      final layout = parseDecorationLayout('close,minimize,maximize:');
      expect(
        layout.start,
        [WindowButton.close, WindowButton.minimize, WindowButton.maximize],
      );
      expect(layout.end, isEmpty);
    });

    test('buttons can straddle both sides', () {
      final layout = parseDecorationLayout('close:minimize,maximize');
      expect(layout.start, [WindowButton.close]);
      expect(layout.end, [WindowButton.minimize, WindowButton.maximize]);
    });

    test('order within a side is preserved, not normalised', () {
      final layout = parseDecorationLayout(':close,minimize,maximize');
      expect(
        layout.end,
        [WindowButton.close, WindowButton.minimize, WindowButton.maximize],
      );
    });

    test('icon and menu tokens parse to nothing, since we draw neither', () {
      final layout = parseDecorationLayout('icon,menu:close');
      expect(layout.start, isEmpty);
      expect(layout.end, [WindowButton.close]);
    });

    test('surrounding whitespace on tokens is tolerated', () {
      final layout = parseDecorationLayout(' appmenu : close , minimize ');
      expect(layout.start, isEmpty);
      expect(layout.end, [WindowButton.close, WindowButton.minimize]);
    });

    test(
        'only the FIRST colon splits, matching g_strsplit(layout, ":", 2) — '
        'so a second colon is swallowed into the end side and its tokens '
        'stop being recognisable', () {
      final layout = parseDecorationLayout('close:minimize:maximize');
      expect(layout.start, [WindowButton.close]);
      expect(layout.end, isEmpty);
    });

    for (final raw in ['', '   ', 'appmenu:', ':', 'garbage,junk:nonsense']) {
      test(
          'falls back to three end-side buttons for ${raw.isEmpty ? "an "
              "empty string" : "'$raw'"}', () {
        final layout = parseDecorationLayout(raw);
        expect(layout.start, isEmpty);
        expect(
          layout.end,
          [WindowButton.minimize, WindowButton.maximize, WindowButton.close],
        );
      });
    }

    test('the fallback constant itself parses to what the fallback promises',
        () {
      final layout = parseDecorationLayout(kFallbackDecorationLayout);
      expect(layout.start, isEmpty);
      expect(
        layout.end,
        [WindowButton.minimize, WindowButton.maximize, WindowButton.close],
      );
    });
  });

  group('DecorationLayout', () {
    test('is a value type, so a rebuild on an identical layout is a no-op', () {
      expect(
        parseDecorationLayout('appmenu:close'),
        parseDecorationLayout('icon:close'),
      );
      expect(
        parseDecorationLayout('appmenu:close').hashCode,
        parseDecorationLayout('icon:close').hashCode,
      );
    });

    test('differs when the same buttons sit on the other side', () {
      expect(
        parseDecorationLayout('close:'),
        isNot(parseDecorationLayout(':close')),
      );
    });

    test('isEmpty is false for anything the fallback produces', () {
      expect(parseDecorationLayout('').isEmpty, isFalse);
    });
  });
}
