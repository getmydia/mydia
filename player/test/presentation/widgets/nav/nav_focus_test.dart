// The sidebar is the first thing a D-pad viewer lands on and the only way to
// reach anything other than Home. Before this it was a MouseRegion wrapping a
// GestureDetector with no focus node, so a remote could not move between rows
// at all.

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';
import 'package:player/presentation/widgets/nav/sidebar_row.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(body: Center(child: child)),
    );

void main() {
  testWidgets('a sidebar row is a focus stop', (tester) async {
    await tester.pumpWidget(
      _host(
        SidebarRow(
          icon: Icons.home_rounded,
          selectedIcon: Icons.home_rounded,
          label: 'Home',
          isSelected: false,
          onTap: () {},
        ),
      ),
    );

    expect(find.byType(FocusHighlight), findsOneWidget);
    final detector = tester.widget<FocusableActionDetector>(
      find.byType(FocusableActionDetector).first,
    );
    expect(detector.enabled, isTrue);
  });

  testWidgets('Enter on a focused sidebar row navigates', (tester) async {
    var taps = 0;

    await tester.pumpWidget(
      _host(
        SidebarRow(
          icon: Icons.home_rounded,
          selectedIcon: Icons.home_rounded,
          label: 'Home',
          isSelected: false,
          onTap: () => taps++,
        ),
      ),
    );

    final scope = FocusScope.of(tester.element(find.byType(SidebarRow)));
    scope.nextFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(taps, 1);
  });

  testWidgets('a row in edit mode is not activatable, matching its null onTap',
      (tester) async {
    var taps = 0;

    await tester.pumpWidget(
      _host(
        SidebarRow(
          icon: Icons.home_rounded,
          selectedIcon: Icons.home_rounded,
          label: 'Home',
          isSelected: false,
          isEditing: true,
          onTap: () => taps++,
        ),
      ),
    );

    final scope = FocusScope.of(tester.element(find.byType(SidebarRow)));
    scope.nextFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(taps, 0);
  });

  testWidgets(
      'a customisable row is a single focus stop when its overflow menu is '
      'hidden', (tester) async {
    // PopupMenuButton wraps a Material IconButton, whose canRequestFocus is
    // onPressed != null regardless of Opacity or IgnorePointer. Without
    // ExcludeFocus around the hidden menu, this row would be a double focus
    // stop, and the second stop is invisible: on a television, showMenu is
    // always false (it is hover- and edit-driven, and a TV has no hover), so
    // this is the case a remote hits on nearly every customisable row.
    await tester.pumpWidget(
      _host(
        SidebarRow(
          icon: Icons.home_rounded,
          selectedIcon: Icons.home_rounded,
          label: 'Home',
          isSelected: false,
          canCustomise: true,
          onTap: () {},
        ),
      ),
    );

    final scope = FocusScope.of(tester.element(find.byType(SidebarRow)));
    expect(
      scope.traversalDescendants.where((node) => node.canRequestFocus).length,
      1,
    );
  });

  testWidgets('the overflow menu rejoins traversal once hover reveals it',
      (tester) async {
    await tester.pumpWidget(
      _host(
        SidebarRow(
          icon: Icons.home_rounded,
          selectedIcon: Icons.home_rounded,
          label: 'Home',
          isSelected: false,
          canCustomise: true,
          onTap: () {},
        ),
      ),
    );

    // Drive showMenu to true the same way a desktop user would: a real mouse
    // hover over the row, rather than reaching into SidebarRow's private
    // _isHovered state.
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.byType(SidebarRow)));
    await tester.pump();

    final scope = FocusScope.of(tester.element(find.byType(SidebarRow)));
    expect(
      scope.traversalDescendants.where((node) => node.canRequestFocus).length,
      2,
    );
  });
}
