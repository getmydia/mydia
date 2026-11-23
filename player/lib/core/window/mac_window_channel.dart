/// Dart side of `macos/Runner/WindowPlugin.swift`.
///
/// On macOS, Dart runs off the main thread (`FLTEnableMergedPlatformUIThread`
/// is false, for mpv; see `docs/playback.md`, "macOS keeps Dart off the main
/// thread"). window_manager 0.7's nativeapi calls AppKit from whatever thread
/// calls it, and from Dart's it cannot find the window at all. A method
/// channel's handler runs on the main thread, so on macOS every window call
/// and window event goes through here instead.
///
/// Rects are top-left, measured from the primary screen, the convention
/// nativeapi used.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'window_chrome_channel.dart';
import 'window_geometry_math.dart';

/// Whether this build drives the window through [MacWindowChannel].
///
/// Read through [defaultTargetPlatform] so tests can switch it with
/// `debugDefaultTargetPlatformOverride`.
bool get useMacWindowChannel =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

/// Receives one event pushed by `WindowPlugin`.
typedef MacWindowEventHandler = void Function(
  String event,
  Map<Object?, Object?>? args,
);

class MacWindowChannel {
  MacWindowChannel({this._channel = _defaultChannel});

  static const MethodChannel _defaultChannel = MethodChannel(
    kMacWindowChannelName,
  );

  static final MacWindowChannel instance = MacWindowChannel();

  final MethodChannel _channel;

  /// Calls [method]. Errors propagate: every caller already decides what a
  /// failed window call means for it.
  Future<T?> invoke<T>(String method, [Object? args]) =>
      _channel.invokeMethod<T>(method, args);

  /// Installs [onEvent] as the receiver of every event `WindowPlugin` pushes.
  /// A later call replaces the earlier receiver.
  void listen(MacWindowEventHandler onEvent) {
    _channel.setMethodCallHandler((call) async {
      final args = call.arguments;
      onEvent(call.method, args is Map ? args.cast<Object?, Object?>() : null);
    });
  }

  /// The displays' usable areas, skipping any that report no size. Never
  /// throws: a failed read returns none, as the nativeapi path does.
  Future<List<WorkArea>> getWorkAreas() async {
    try {
      final raw = await invoke<List<Object?>>('getWorkAreas') ?? const [];
      final areas = <WorkArea>[];
      for (final entry in raw) {
        if (entry is! Map) continue;
        final bounds = decodeRect(entry);
        if (bounds.width <= 0 || bounds.height <= 0) continue;
        areas.add(
          WorkArea(bounds: bounds, isPrimary: entry['isPrimary'] == true),
        );
      }
      return areas;
    } catch (e) {
      debugPrint('[MacWindowChannel] Failed to read work areas: $e');
      return const [];
    }
  }
}

/// A `{x, y, width, height}` map as a [Rect]. Missing or non-numeric values
/// read as zero.
Rect decodeRect(Object? raw) {
  double read(String key) =>
      raw is Map ? ((raw[key] as num?)?.toDouble() ?? 0) : 0;
  return Rect.fromLTWH(read('x'), read('y'), read('width'), read('height'));
}

Map<String, double> encodeRect(Rect rect) => {
  'x': rect.left,
  'y': rect.top,
  'width': rect.width,
  'height': rect.height,
};
