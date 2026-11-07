import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/linux_desktop.dart';

void main() {
  test('parse maps XDG_CURRENT_DESKTOP entries', () {
    expect(LinuxDesktop.parse('GNOME'), LinuxDesktop.gnome);
    expect(LinuxDesktop.parse('ubuntu:GNOME'), LinuxDesktop.gnome);
    expect(LinuxDesktop.parse('GNOME-Classic:GNOME'), LinuxDesktop.gnome);
    expect(LinuxDesktop.parse('Pantheon:GNOME'), LinuxDesktop.elementary);
    expect(LinuxDesktop.parse('GNOME:Pantheon'), LinuxDesktop.elementary);
    expect(LinuxDesktop.parse('KDE'), LinuxDesktop.kde);
    expect(LinuxDesktop.parse('kde'), LinuxDesktop.kde);
    expect(LinuxDesktop.parse('XFCE'), LinuxDesktop.other);
    expect(LinuxDesktop.parse(''), LinuxDesktop.other);
    expect(LinuxDesktop.parse(null), LinuxDesktop.other);
  });

  test('stock accents and names', () {
    expect(LinuxDesktop.gnome.stockAccent, const Color(0xFF3584E4));
    expect(LinuxDesktop.other.stockAccent, const Color(0xFF3584E4));
    expect(LinuxDesktop.kde.stockAccent, const Color(0xFF3DAEE9));
    expect(LinuxDesktop.elementary.stockAccent, const Color(0xFF3689E6));
    expect(LinuxDesktop.gnome.displayName, 'GNOME');
    expect(LinuxDesktop.kde.displayName, 'KDE Plasma');
    expect(LinuxDesktop.elementary.displayName, 'elementary OS');
    expect(LinuxDesktop.other.displayName, isNull);
  });
}
