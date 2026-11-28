/// mpv counters through media_kit's `NativePlayer.getProperty`.
library;

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:media_kit/media_kit.dart';

import 'frame_stats_sampler.dart';
import 'health_sample.dart';

FrameStatsSampler samplerFor(Player player, {bool panel = false}) {
  final platform = player.platform;
  if (platform is! NativePlayer) return const NoFrameStatsSampler();
  return NativeFrameStatsSampler(platform, panel: panel);
}

/// Set by the vendored media_kit_video's Linux video output once it has
/// picked a render path: `hw` or `sw`. Unset everywhere else.
const renderPathProperty = 'user-data/media-kit/render';

class NativeFrameStatsSampler implements FrameStatsSampler {
  NativeFrameStatsSampler(this._platform, {this.panel = false});

  final NativePlayer _platform;

  /// Whether each reading also carries what only the stats panel shows.
  final bool panel;

  @override
  Future<FrameStats?> sample() async {
    try {
      // `frame-drop-count` is frames the VO dropped; `decoder-frame-drop-count`
      // is frames the decoder skipped. Either means decode is behind.
      final vo = int.tryParse(await _platform.getProperty('frame-drop-count'));
      final decoder = int.tryParse(
        await _platform.getProperty('decoder-frame-drop-count'),
      );
      // A read where either counter fails to parse cannot be trusted: the
      // cumulative total would silently drop, and the next good read would
      // make the monitor count that whole gap as new drops.
      if (vo == null || decoder == null) return null;
      // `cache-speed` is bytes per second of network read.
      final speed = double.tryParse(await _platform.getProperty('cache-speed'));
      return FrameStats(
        droppedFrames: vo + decoder,
        throughputKbps: speed == null ? null : (speed * 8 / 1000).round(),
        targetGamma: panel
            ? await _optional('video-target-params/gamma')
            : null,
        colormatrix: panel ? await _optional('video-params/colormatrix') : null,
        sourceColor: panel ? await _color('video-params') : null,
        outputColor: panel ? await _color('video-target-params') : null,
        softwareRendering: panel ? await _softwareRendering() : null,
      );
    } catch (e) {
      debugPrint('[FrameStats] mpv property read failed: $e');
      return null;
    }
  }

  /// `<prefix>/primaries`, `/gamma` and `/max-luma`; null when mpv reports
  /// neither primaries nor gamma (no video yet).
  Future<ColorParams?> _color(String prefix) async {
    final color = ColorParams(
      primaries: await _optional('$prefix/primaries'),
      gamma: await _optional('$prefix/gamma'),
      peakNits: double.tryParse(await _optional('$prefix/max-luma') ?? ''),
    );
    return color.isEmpty ? null : color;
  }

  /// True for `sw`, false for `hw`, null when unset or unrecognised.
  ///
  /// libmpv hands a `user-data/` string back JSON-encoded, quotes included
  /// (`"sw"`), so both forms are matched.
  Future<bool?> _softwareRendering() async =>
      switch (await _optional(renderPathProperty)) {
        'sw' || '"sw"' => true,
        'hw' || '"hw"' => false,
        _ => null,
      };

  /// A property that is allowed to be unset (no video yet, or a video
  /// output that reports no target). Its failure never invalidates the
  /// counters above.
  Future<String?> _optional(String name) async {
    try {
      final value = (await _platform.getProperty(name)).trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }
}
