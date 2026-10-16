import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/window_chrome_inset.dart';
import 'package:player/core/layout/breakpoints.dart';
import 'package:player/core/platform/native_tab_bar_channel.dart';
import 'package:player/core/platform/native_tab_bar_support.dart';
import 'package:player/presentation/widgets/app_shell.dart';

void main() {
  group('showsSidebarLayout', () {
    test('the native sidebar follows the native width class', () {
      expect(
          AppShell.showsSidebarLayout(
              mode: NativeTabBarMode.sidebar,
              nativeRegular: false,
              flutterShowsRail: true),
          isFalse);
      expect(
          AppShell.showsSidebarLayout(
              mode: NativeTabBarMode.sidebar,
              nativeRegular: true,
              flutterShowsRail: false),
          isTrue);
    });

    test('everywhere else the Flutter breakpoint decides', () {
      for (final mode in [NativeTabBarMode.none, NativeTabBarMode.bar]) {
        expect(
            AppShell.showsSidebarLayout(
                mode: mode, nativeRegular: false, flutterShowsRail: true),
            isTrue);
      }
    });
  });

  group('nativeSidebarContentLeft', () {
    test('before any report, the collapsed rail inset', () {
      expect(AppShell.nativeSidebarContentLeft(insets: null, safeLeft: 0),
          Breakpoints.railContentInset(pinned: false));
    });

    test('the sidebar edge plus the rail gap', () {
      expect(
          AppShell.nativeSidebarContentLeft(
              insets: const NativeInsets(leading: 320), safeLeft: 0),
          320 + Breakpoints.railGap);
    });

    test('the safe area is not counted twice', () {
      expect(
          AppShell.nativeSidebarContentLeft(
              insets: const NativeInsets(leading: 340), safeLeft: 20),
          320 + Breakpoints.railGap);
    });

    test('a hidden sidebar leaves only the gap', () {
      expect(
          AppShell.nativeSidebarContentLeft(
              insets: const NativeInsets(top: 74), safeLeft: 0),
          Breakpoints.railGap);
    });
  });

  group('macOS pane rules', () {
    const mac = TargetPlatform.macOS;
    const ios = TargetPlatform.iOS;
    const chrome = WindowChromeInsets(height: 40, leading: 80, trailing: 0);

    test('the sidebar is a pane only on macOS', () {
      expect(AppShell.nativeSidebarIsPane(mac), isTrue);
      expect(AppShell.nativeSidebarIsPane(ios), isFalse);
    });

    test('content starts at 0 beside the macOS pane', () {
      expect(
          AppShell.nativeSidebarContentLeftFor(
              platform: mac, insets: null, safeLeft: 0),
          0);
      expect(
          AppShell.nativeSidebarContentLeftFor(
              platform: ios,
              insets: const NativeInsets(leading: 320),
              safeLeft: 0),
          AppShell.nativeSidebarContentLeft(
              insets: const NativeInsets(leading: 320), safeLeft: 0));
    });

    test('macOS content reserves the reported chrome, constant until then', () {
      double leadingFor(NativeInsets? insets) =>
          AppShell.nativeSidebarContentChrome(
                  platform: mac, chrome: chrome, insets: insets)
              .leading;
      expect(leadingFor(null), 80);
      expect(
          leadingFor(const NativeInsets(chromeLeading: 0, reportsChrome: true)),
          0);
      expect(
          leadingFor(
              const NativeInsets(chromeLeading: 124, reportsChrome: true)),
          124);
      expect(leadingFor(const NativeInsets(leading: 300)), 80);
      expect(
          AppShell.nativeSidebarContentChrome(
                  platform: mac, chrome: chrome, insets: null)
              .height,
          40);
    });

    test('iPad content keeps the rail rule', () {
      final got = AppShell.nativeSidebarContentChrome(
          platform: ios, chrome: chrome, insets: null);
      final want = AppShell.contentInsets(chrome);
      expect(got.height, want.height);
      expect(got.leading, want.leading);
      expect(got.trailing, want.trailing);
    });

    test('popups never hide the macOS sidebar, pages do', () {
      expect(
          AppShell.nativeSidebarVisible(
              platform: mac,
              shellCurrent: false,
              shellPopup: true,
              coveredByPage: false),
          isTrue);
      expect(
          AppShell.nativeSidebarVisible(
              platform: mac,
              shellCurrent: false,
              shellPopup: false,
              coveredByPage: true),
          isFalse);
    });

    test('popups still hide the iPad sidebar', () {
      expect(
          AppShell.nativeSidebarVisible(
              platform: ios,
              shellCurrent: true,
              shellPopup: true,
              coveredByPage: false),
          isFalse);
    });
  });
}
