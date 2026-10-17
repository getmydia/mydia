import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/native_tab_bar_channel.dart';
import 'palette.dart';

/// The macOS system accent colour, live. [Palettes.macosDefaultAccent]
/// until native answers, and always off native macOS.
///
/// Hand-written rather than `@riverpod`: riverpod_generator throws
/// `InvalidTypeException` on a notifier whose state type is `Color`.
final systemAccentProvider = NotifierProvider<SystemAccent, Color>(
  SystemAccent.new,
);

class SystemAccent extends Notifier<Color> {
  /// Forces the platform check in tests. Reset to null in `tearDown`.
  @visibleForTesting
  static bool? debugIsNativeMacOS;

  static bool get _isNativeMacOS =>
      debugIsNativeMacOS ??
      (!kIsWeb && defaultTargetPlatform == TargetPlatform.macOS);

  @override
  Color build() {
    if (!_isNativeMacOS) return Palettes.macosDefaultAccent;
    final channel = ref.watch(nativeTabBarChannelProvider);
    final sub = channel.events.listen((event) {
      if (event is NativeSystemAccentChanged) state = event.color;
    });
    ref.onDispose(sub.cancel);
    unawaited(channel.querySystemAccent().then((color) {
      if (color != null && ref.mounted) state = color;
    }));
    return Palettes.macosDefaultAccent;
  }
}
