// `Override` is not re-exported by the main `flutter_riverpod.dart` barrel in
// Riverpod 3.x; it lives in the `misc.dart` sub-library alongside other
// advanced/library-author types. Mirrors `cast_button_test.dart`.
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';

/// Overrides that make [CastButton] render.
///
/// `castCapabilitiesProvider` otherwise resolves to
/// `CastCapabilities.forCurrentPlatform()`, which is `.web()` (no protocol
/// capable) under `flutter test`'s host platform, and `CastButton` shrinks to
/// nothing whenever `.any` is false. Any widget test that needs the button to
/// actually render (rather than specifically exercising its hidden state)
/// pulls this in instead of repeating the override inline.
List<Override> castCapableOverrides() => [
      castCapabilitiesProvider.overrideWithValue(const CastCapabilities.full()),
    ];
