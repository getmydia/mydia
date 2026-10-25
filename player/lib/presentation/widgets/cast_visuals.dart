import 'package:flutter/material.dart';

import '../../core/cast/cast_providers.dart';
import '../../l10n/l10n.dart';

/// How a cast affordance reads in a given [CastConnection].
///
/// Shared by `CastButton` and `CastChromeIcon` so the two cannot drift into
/// disagreeing about what a connection state means.
///
/// Deliberately returns whether the receiver is *connected* rather than an
/// [IconData]: the two affordances draw from different Material icon families
/// — the playback chrome is `_rounded` throughout (see
/// `video_controls/icon_family_test.dart`), while app bars and the shell
/// overlay use the bare family. Handing back a concrete glyph would force one
/// of them into the wrong family, which is the exact drift that test exists to
/// catch. Colour and tooltip, which must match everywhere, are shared.
typedef CastVisuals = ({bool connected, Color color, String tooltip});

/// `connected` is true only when a connection is genuinely live, because
/// `cast_connected` is the platform's "this app owns that receiver" glyph. A
/// device that has merely been chosen stays hollow, in the same blue.
CastVisuals castVisualsFor(
  AppLocalizations l10n,
  CastConnection connection,
  String? deviceName,
) {
  final name = deviceName ?? l10n.castDeviceFallbackName;
  return switch (connection) {
    CastConnection.none => (
        connected: false,
        color: Colors.white,
        tooltip: l10n.castTooltipIdle,
      ),
    CastConnection.connecting => (
        connected: false,
        color: Colors.blue,
        tooltip: l10n.castTooltipConnecting(name),
      ),
    CastConnection.connectedIdle => (
        connected: true,
        color: Colors.blue,
        tooltip: l10n.castTooltipConnected(name),
      ),
    CastConnection.casting => (
        connected: true,
        color: Colors.blue,
        tooltip: l10n.castTooltipCasting(name),
      ),
    CastConnection.chosenOffline => (
        connected: false,
        color: Colors.blue,
        tooltip: l10n.castTooltipOffline(name),
      ),
  };
}
