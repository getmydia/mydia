import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:player/core/playback/frame_stats_sampler_native.dart';

/// Answers `getProperty` from [props] (empty when unset, as mpv does).
/// Nothing else is used: `NativePlayer`'s own constructor opens libmpv.
class _PropertyPlayer implements NativePlayer {
  _PropertyPlayer(this.props);

  final Map<String, String> props;

  @override
  Future<String> getProperty(
    String property, {
    bool waitForInitialization = true,
  }) async => props[property] ?? '';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<bool?> _softwareRendering(String? render) async {
  final stats = await NativeFrameStatsSampler(
    _PropertyPlayer({
      'frame-drop-count': '0',
      'decoder-frame-drop-count': '0',
      renderPathProperty: ?render,
    }),
    panel: true,
  ).sample();
  expect(stats, isNotNull, reason: 'the counters parsed, so a reading');
  return stats!.softwareRendering;
}

void main() {
  group('softwareRendering', () {
    // libmpv returns the property JSON-encoded, which is what the Linux
    // video output's value looks like in practice.
    test('reads the quoted form libmpv returns', () async {
      expect(await _softwareRendering('"sw"'), isTrue);
      expect(await _softwareRendering('"hw"'), isFalse);
    });

    test('reads the bare form', () async {
      expect(await _softwareRendering('sw'), isTrue);
      expect(await _softwareRendering('hw'), isFalse);
    });

    test('is null when unset or unrecognised', () async {
      expect(await _softwareRendering(null), isNull);
      expect(await _softwareRendering('"gpu"'), isNull);
    });

    test('is left out of readings for the overlay', () async {
      final stats = await NativeFrameStatsSampler(
        _PropertyPlayer({
          'frame-drop-count': '0',
          'decoder-frame-drop-count': '0',
          renderPathProperty: '"sw"',
        }),
      ).sample();
      expect(stats?.softwareRendering, isNull);
    });
  });
}
