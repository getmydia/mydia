import 'package:flutter/foundation.dart';

import 'decoration_layout.dart';

/// No-op on web: there is no GTK, and no OS window whose buttons we draw.
///
/// Holds the fallback forever so callers can read `layout.value`
/// unconditionally. Mirrors `desktop_window_stub.dart`.
class DecorationLayoutSource {
  DecorationLayoutSource();

  final ValueNotifier<DecorationLayout> _layout =
      ValueNotifier<DecorationLayout>(
    parseDecorationLayout(kFallbackDecorationLayout),
  );

  ValueListenable<DecorationLayout> get layout => _layout;

  Future<void> load() async {}

  void dispose() => _layout.dispose();
}
