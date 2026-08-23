import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/presentation/widgets/nav/sidebar_row.dart';

Future<void> _pumpRow(
  WidgetTester tester, {
  required bool isEditing,
  bool isHidden = false,
  bool canCustomise = true,
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
            canCustomise: canCustomise,
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

/// The 36px trailing slot every customisable row already reserves for its
/// overflow menu. Edit mode reuses this same width for the grip/restore
/// slot, so a slot of exactly this width must persist while editing.
const _menuWidth = 36.0;

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

  testWidgets(
      'editing reserves the trailing slot even when editingTrailing is '
      'omitted', (tester) async {
    await _pumpRow(tester, isEditing: true);

    final slot = tester.widget<SizedBox>(
      find.byWidgetPredicate(
        (widget) => widget is SizedBox && widget.width == _menuWidth,
      ),
    );

    expect(slot.width, _menuWidth);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });

  testWidgets(
      'a non-customisable row still shows a supplied editingTrailing while '
      'editing', (tester) async {
    await _pumpRow(
      tester,
      isEditing: true,
      canCustomise: false,
      editingTrailing: const Icon(Icons.drag_indicator, key: Key('grip')),
    );

    expect(find.byKey(const Key('grip')), findsOneWidget);
    expect(find.byType(PopupMenuButton<String>), findsNothing);
  });
}
