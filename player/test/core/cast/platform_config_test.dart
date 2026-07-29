import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// These files are the reason casting never worked on mobile: without the
/// Bonjour declarations iOS silently returns zero mDNS results.
void main() {
  group('platform cast configuration', () {
    test('iOS Info.plist declares the Chromecast Bonjour service', () {
      final plist = File('ios/Runner/Info.plist').readAsStringSync();

      expect(plist, contains('NSBonjourServices'));
      expect(plist, contains('_googlecast._tcp'));
      expect(plist, contains('NSLocalNetworkUsageDescription'));
    });

    test('no empty iOS entitlements file is left behind', () {
      // Casting on iOS needs Info.plist declarations, not entitlements: the
      // multicast entitlement is explicitly out of scope. An empty
      // entitlements plist referenced from the build settings signs nothing
      // and only invites confusion, so neither should exist.
      final pbxproj =
          File('ios/Runner.xcodeproj/project.pbxproj').readAsStringSync();

      expect(File('ios/Runner/Runner.entitlements').existsSync(), isFalse);
      expect(pbxproj, isNot(contains('Runner.entitlements')));
    });

    test('macOS Info.plist declares local network usage', () {
      final plist = File('macos/Runner/Info.plist').readAsStringSync();

      expect(plist, contains('NSLocalNetworkUsageDescription'));
    });

    test('Android manifest requests multicast permission', () {
      final manifest =
          File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

      expect(manifest, contains('android.permission.CHANGE_WIFI_MULTICAST_STATE'));
    });

    test('flutter_chrome_cast is no longer a dependency', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();

      expect(pubspec, isNot(contains('flutter_chrome_cast')));
      expect(pubspec, contains('dart_cast'));
      expect(pubspec, contains('bonsoir'));
    });
  });
}
