import 'package:flutter_test/flutter_test.dart';
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
}
