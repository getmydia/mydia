import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/nav/sidebar_row.dart';

Future<void> _pumpRow(
  WidgetTester tester, {
  required bool canCustomise,
  TextScaler textScaler = TextScaler.noScaling,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(textScaler: textScaler),
        child: child!,
      ),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 260,
            child: SidebarRow(
              icon: Icons.movie_outlined,
              selectedIcon: Icons.movie,
              label: 'Movies',
              isSelected: false,
              canCustomise: canCustomise,
              onTap: () {},
              onHide: () {},
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The row's own box: the pill the selection and hover fills paint.
Size _rowSize(WidgetTester tester) => tester.getSize(find
    .descendant(
        of: find.byType(SidebarRow), matching: find.byType(AnimatedContainer))
    .first);

void main() {
  testWidgets('an anchored row is 44pt tall', (tester) async {
    await _pumpRow(tester, canCustomise: false);
    expect(_rowSize(tester).height, 44);
  });

  testWidgets('the overflow menu does not make a customisable row taller',
      (tester) async {
    await _pumpRow(tester, canCustomise: true);
    expect(_rowSize(tester).height, 44);
  });

  testWidgets('larger text grows the row past 44pt', (tester) async {
    await _pumpRow(
      tester,
      canCustomise: false,
      // 15pt label text: at 2x its line box (about 36pt) still fits the
      // 44pt minimum, at 3x it does not.
      textScaler: const TextScaler.linear(3),
    );
    expect(_rowSize(tester).height, greaterThan(44));
  });

  testWidgets('the overflow menu hit area spans the row height',
      (tester) async {
    await _pumpRow(tester, canCustomise: true);
    expect(tester.getSize(find.byType(PopupMenuButton<String>)).height, 44);
  });
}
