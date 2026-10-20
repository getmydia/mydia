import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/settings/settings_screen.dart';
import 'package:player/presentation/screens/settings/widgets/settings_row.dart';
import 'package:player/presentation/widgets/focus_highlight.dart';

Widget _app({required bool tv}) => MaterialApp(
      home: Scaffold(
        body: SettingsInitialFocus(
          directionalPrimary: tv,
          child: ListView(
            children: [
              SettingsRow.navigation(
                icon: Icons.hd,
                title: 'First',
                onTap: () {},
              ),
              SettingsRow.navigation(
                icon: Icons.hd,
                title: 'Second',
                onTap: () {},
              ),
            ],
          ),
        ),
      ),
    );

/// The focus node FocusHighlight owns for [title]'s row. Asked from the ring,
/// which sits directly under the detector's Focus, so the lookup does not land
/// on the InkWell's own (non-focusable) node.
FocusNode _node(WidgetTester tester, String title) {
  final ring = find.ancestor(
    of: find.text(title),
    matching: find.byKey(FocusHighlight.ringKey),
  );
  return Focus.of(tester.element(ring.first));
}

void main() {
  testWidgets('on a television the first row takes focus', (tester) async {
    await tester.pumpWidget(_app(tv: true));
    await tester.pump();
    expect(
      _node(tester, 'First').hasPrimaryFocus,
      isTrue,
    );
  });

  testWidgets('elsewhere nothing is focused on open', (tester) async {
    await tester.pumpWidget(_app(tv: false));
    await tester.pump();
    expect(
      _node(tester, 'First').hasPrimaryFocus,
      isFalse,
    );
  });
}
