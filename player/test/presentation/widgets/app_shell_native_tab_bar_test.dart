import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/platform/native_tab_bar_channel.dart';
import 'package:player/presentation/widgets/app_shell.dart';
import 'package:player/presentation/widgets/nav/bottom_nav.dart';
import 'package:player/presentation/widgets/nav/native_tab_bar.dart';

import '../../test_utils/dock_harness.dart' show kDockNavEntries;

const _channel = MethodChannel('test/native-tab-bar');

Future<void> _pump(WidgetTester tester, {required bool native}) async {
  tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, (call) async => null);
  addTearDown(() => tester.binding.defaultBinaryMessenger
      .setMockMethodCallHandler(_channel, null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      nativeTabBarChannelProvider.overrideWith((ref) {
        final channel = NativeTabBarChannel(channel: _channel);
        ref.onDispose(channel.dispose);
        return channel;
      }),
    ],
    child: MaterialApp(
      home: Scaffold(
        bottomNavigationBar: AppShell.mobileBottomBar(
          native: native,
          drawerOpen: false,
          shellCurrent: true,
          location: '/',
          entries: kDockNavEntries,
          isOffline: false,
          showBackToMydia: false,
          settingsBadge: null,
          onNavigate: (_) {},
        ),
      ),
    ),
  ));
  await tester.pump();
}

void main() {
  testWidgets('unsupported: BottomNav exactly as today', (tester) async {
    await _pump(tester, native: false);
    expect(find.byType(BottomNav), findsOneWidget);
    expect(find.byType(NativeTabBar), findsNothing);
  });

  testWidgets('supported: the native bar instead of BottomNav', (tester) async {
    await _pump(tester, native: true);
    expect(find.byType(NativeTabBar), findsOneWidget);
    expect(find.byType(BottomNav), findsNothing);
  });

  test('visible only while the shell is current and the drawer is closed', () {
    expect(AppShell.nativeBarVisible(shellCurrent: true, drawerOpen: false),
        isTrue);
    expect(AppShell.nativeBarVisible(shellCurrent: false, drawerOpen: false),
        isFalse);
    expect(AppShell.nativeBarVisible(shellCurrent: true, drawerOpen: true),
        isFalse);
  });
}
