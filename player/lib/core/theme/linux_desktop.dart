import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The Linux desktop the player runs under, which picks the grey ramp and
/// the stock accent of the `linux` theme preset.
enum LinuxDesktop {
  gnome(Color(0xFF3584E4), 'GNOME'),
  kde(Color(0xFF3DAEE9), 'KDE Plasma'),
  elementary(Color(0xFF3689E6), 'elementary OS'),

  /// Any other desktop (XFCE, Cinnamon, Sway...). Drawn like GNOME, since
  /// most of them run GTK apps styled close to Adwaita.
  other(Color(0xFF3584E4), null);

  const LinuxDesktop(this.stockAccent, this.displayName);

  /// The desktop's own default accent, used when the portal reports none.
  final Color stockAccent;

  /// The desktop's proper name, shown in the theme label; null for [other].
  final String? displayName;

  /// Reads `XDG_CURRENT_DESKTOP`, a colon-separated list. Pantheon wins
  /// wherever it appears, since elementary sessions also list GNOME.
  static LinuxDesktop parse(String? xdgCurrentDesktop) {
    final entries = (xdgCurrentDesktop ?? '')
        .split(':')
        .map((e) => e.trim().toLowerCase())
        .toList();
    if (entries.contains('pantheon')) return elementary;
    if (entries.contains('kde')) return kde;
    if (entries.any((e) => e.startsWith('gnome'))) return gnome;
    return other;
  }
}

/// The desktop this process runs under. [LinuxDesktop.other] on the web.
final linuxDesktopProvider = Provider<LinuxDesktop>((ref) {
  if (kIsWeb) return LinuxDesktop.other;
  return LinuxDesktop.parse(Platform.environment['XDG_CURRENT_DESKTOP']);
});
