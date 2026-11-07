import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/app_shell.dart';
import 'package:player/presentation/widgets/nav/menu_page.dart';

/// Pumps a narrow shell stand-in whose Scaffold has [drawer], wrapped in a
/// [ShellMenuScope] when [open] is given, and taps a button that calls
/// [AppShell.openNavigation] from inside it.
Future<void> _pumpAndOpen(
  WidgetTester tester, {
  Widget? drawer,
  VoidCallback? open,
}) async {
  final scaffold = Scaffold(
    key: AppShell.scaffoldKey,
    drawer: drawer,
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () => AppShell.openNavigation(context),
        child: const Text('menu'),
      ),
    ),
  );
  await tester.pumpWidget(MaterialApp(
    home: open == null ? scaffold : ShellMenuScope(open: open, child: scaffold),
  ));
  await tester.tap(find.text('menu'));
  await tester.pumpAndSettle();
}

void main() {
  group('usesMenuPage', () {
    test('the iOS app opens a menu page', () {
      expect(
        AppShell.usesMenuPage(platform: TargetPlatform.iOS, isWeb: false),
        isTrue,
      );
    });

    test('Safari on an iPhone keeps the drawer', () {
      expect(
        AppShell.usesMenuPage(platform: TargetPlatform.iOS, isWeb: true),
        isFalse,
      );
    });

    for (final platform in TargetPlatform.values) {
      if (platform == TargetPlatform.iOS) continue;
      test('${platform.name} keeps the drawer', () {
        expect(
            AppShell.usesMenuPage(platform: platform, isWeb: false), isFalse);
      });
    }
  });

  group('openNavigation', () {
    testWidgets('opens the menu page where the shell provides one',
        (tester) async {
      var opened = 0;
      await _pumpAndOpen(tester, open: () => opened++);
      expect(opened, 1);
    });

    testWidgets('opens the drawer everywhere else', (tester) async {
      await _pumpAndOpen(
        tester,
        drawer: const Drawer(child: Text('drawer-body')),
      );
      expect(find.text('drawer-body'), findsOneWidget);
    });
  });
}
