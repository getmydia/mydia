import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/presentation/widgets/nav/sidebar_row.dart';

Future<void> _pumpRow(
  WidgetTester tester, {
  required bool isEditing,
  bool isHidden = false,
  Widget? editingTrailing,
  VoidCallback? onTap,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 260,
          child: SidebarRow(
            icon: Icons.movie_outlined,
            selectedIcon: Icons.movie,
            label: 'Movies',
            isSelected: false,
            canCustomise: true,
            isEditing: isEditing,
            isHidden: isHidden,
            editingTrailing: editingTrailing,
            onTap: onTap ?? () {},
            onHide: () {},
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('editing suppresses the row tap', (tester) async {
    var taps = 0;
    await _pumpRow(tester, isEditing: true, onTap: () => taps++);

    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();

    expect(taps, 0);
  });

  testWidgets('a normal row still taps', (tester) async {
    var taps = 0;
    await _pumpRow(tester, isEditing: false, onTap: () => taps++);

    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();

    expect(taps, 1);
  });

  testWidgets('editing renders editingTrailing instead of the menu',
      (tester) async {
    await _pumpRow(
      tester,
      isEditing: true,
      editingTrailing: const Icon(Icons.drag_indicator, key: Key('grip')),
    );

    expect(find.byKey(const Key('grip')), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });

  testWidgets('a normal customizable row keeps its overflow menu',
      (tester) async {
    await _pumpRow(tester, isEditing: false);

    expect(find.byType(PopupMenuButton<String>), findsOneWidget);
  });

  testWidgets('a hidden row strikes its label and dims it', (tester) async {
    await _pumpRow(
      tester,
      isEditing: true,
      isHidden: true,
      editingTrailing: const Icon(Icons.add_circle, key: Key('restore')),
    );

    final text = tester.widget<Text>(find.text('Movies'));
    expect(text.style?.decoration, TextDecoration.lineThrough);
    expect(text.style?.color, AppColors.textDisabled);
  });

  testWidgets('editing does not long-press into the menu', (tester) async {
    await _pumpRow(
      tester,
      isEditing: true,
      editingTrailing: const Icon(Icons.drag_indicator, key: Key('grip')),
    );

    await tester.longPress(find.text('Movies'));
    await tester.pumpAndSettle();

    expect(find.text('Hide'), findsNothing);
  });
}
