import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/theme/app_theme.dart';
import 'package:player/core/theme/palette.dart';
import 'package:player/presentation/widgets/glass/glass_dialog.dart';
import 'package:player/presentation/widgets/glass_surface.dart';

ThemeData _theme({required bool liquid}) =>
    AppTheme.build(Palettes.projectionBooth, liquid: liquid);

Widget _host({required bool liquid}) => MaterialApp(
      theme: _theme(liquid: liquid),
      home: Scaffold(
        body: GlassDialog(
          icon: const Icon(Icons.warning_rounded),
          title: const Text('Remove account?'),
          content: const Text('This signs you out.'),
          actions: [
            TextButton(onPressed: () {}, child: const Text('Cancel')),
            FilledButton(onPressed: () {}, child: const Text('Remove')),
          ],
        ),
      ),
    );

void main() {
  _focusTests();
  testWidgets('Liquid Glass: laid out on modal glass', (tester) async {
    await tester.pumpWidget(_host(liquid: true));
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(GlassSurface), findsOneWidget);
    for (final text in [
      'Remove account?',
      'This signs you out.',
      'Cancel',
      'Remove',
    ]) {
      expect(find.text(text), findsOneWidget);
    }
    expect(find.byIcon(Icons.warning_rounded), findsOneWidget);
  });

  testWidgets('Frosted: it is the AlertDialog it replaced', (tester) async {
    await tester.pumpWidget(_host(liquid: false));
    final dialog = tester.widget<AlertDialog>(find.byType(AlertDialog));
    expect((dialog.title! as Text).data, 'Remove account?');
    // The actions ride under one container node so the default target can be
    // found.
    expect(dialog.actions, hasLength(1));
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Remove'), findsOneWidget);
  });
  testWidgets('Liquid Glass: tall content scrolls instead of overflowing',
      (tester) async {
    tester.view.physicalSize = const Size(400, 500);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: _theme(liquid: true),
      home: Scaffold(
        body: Center(
          child: GlassDialog(
            title: const Text('Logs'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [for (var i = 0; i < 60; i++) Text('Row $i')],
            ),
            actions: [TextButton(onPressed: () {}, child: const Text('OK'))],
          ),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });
}

/// Opens a [GlassDialog] through a real route so the route's focus scope is
/// the one the dialog's default-focus fallback inspects.
Future<void> _openDialog(
  WidgetTester tester, {
  required bool liquid,
  bool destructive = false,
  Widget? content,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: _theme(liquid: liquid),
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => GlassDialog(
            destructive: destructive,
            title: const Text('Confirm'),
            content: content,
            actions: [
              TextButton(
                key: const Key('first'),
                onPressed: () {},
                child: const Text('Cancel'),
              ),
              FilledButton(
                key: const Key('last'),
                onPressed: () {},
                child: const Text('Okay'),
              ),
            ],
          ),
        ),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

bool _hasFocus(WidgetTester tester, Key key) => Focus.of(
      tester.element(find.descendant(
        of: find.byKey(key),
        matching: find.byType(Text),
      )),
    ).hasPrimaryFocus;

void _focusTests() {
  for (final liquid in [true, false]) {
    final mode = liquid ? 'Liquid Glass' : 'Frosted';
    group('$mode default focus', () {
      testWidgets('lands on the last (primary) action', (tester) async {
        await _openDialog(tester, liquid: liquid);
        expect(_hasFocus(tester, const Key('last')), isTrue);
        expect(_hasFocus(tester, const Key('first')), isFalse);
      });

      testWidgets('destructive lands on the first action', (tester) async {
        await _openDialog(tester, liquid: liquid, destructive: true);
        expect(_hasFocus(tester, const Key('first')), isTrue);
        expect(_hasFocus(tester, const Key('last')), isFalse);
      });

      testWidgets('content that autofocuses keeps its focus', (tester) async {
        await _openDialog(
          tester,
          liquid: liquid,
          content: const TextField(key: Key('field'), autofocus: true),
        );
        final field =
            tester.state<EditableTextState>(find.byType(EditableText));
        expect(field.widget.focusNode.hasPrimaryFocus, isTrue);
        expect(_hasFocus(tester, const Key('last')), isFalse);
      });

      testWidgets('UP from an action reaches the content', (tester) async {
        await _openDialog(
          tester,
          liquid: liquid,
          content: TextButton(
            key: const Key('content'),
            onPressed: () {},
            child: const Text('Add a note'),
          ),
        );
        expect(_hasFocus(tester, const Key('last')), isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pumpAndSettle();
        expect(_hasFocus(tester, const Key('content')), isTrue);
      });
    });
  }
}
