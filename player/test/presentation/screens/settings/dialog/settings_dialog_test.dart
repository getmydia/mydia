import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/screens/settings/dialog/settings_dialog.dart';

Widget _page(SettingsCategory c) => Builder(
      builder: (context) => SettingsPane(
        title: c.label,
        child: TextButton(
          key: Key('push-${c.name}'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => SettingsPane(
              title: '${c.label} detail',
              child: const SizedBox.shrink(),
            ),
          )),
          child: Text('root ${c.name}'),
        ),
      ),
    );

Future<SettingsDialogController> _open(WidgetTester tester,
    {Size size = const Size(1280, 800),
    SettingsCategory initial = SettingsCategory.playback}) async {
  // setSurfaceSize leaves MediaQuery at the default 800x600, so drive the
  // view itself.
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final controller = SettingsDialogController(initial);
  await tester.pumpWidget(MaterialApp(
    home: Builder(
      builder: (context) => TextButton(
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) =>
              SettingsDialog(controller: controller, rootPage: _page),
        ),
        child: const Text('open'),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return controller;
}

void main() {
  testWidgets('lists the four categories and shows the selected one',
      (tester) async {
    await _open(tester);
    for (final c in SettingsCategory.values) {
      expect(find.byKey(Key('settings-category-${c.name}')), findsOneWidget);
    }
    expect(find.text('root playback'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-category-about')));
    await tester.pumpAndSettle();
    expect(find.text('root about'), findsOneWidget);
  });

  testWidgets('each category keeps its own stack', (tester) async {
    await _open(tester, initial: SettingsCategory.servers);
    await tester.tap(find.byKey(const Key('push-servers')));
    await tester.pumpAndSettle();
    expect(find.text('Servers detail'), findsOneWidget);

    await tester.tap(find.byKey(const Key('settings-category-diagnostics')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('settings-category-servers')));
    await tester.pumpAndSettle();
    expect(find.text('Servers detail'), findsOneWidget);
  });

  testWidgets('Esc pops the pane first, then closes', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('push-playback')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog-back')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('root playback'), findsOneWidget);
    expect(find.byKey(const Key('settings-dialog')), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog')), findsNothing);
  });

  testWidgets('the close button closes', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const Key('settings-dialog-close')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('settings-dialog')), findsNothing);
  });

  testWidgets('the controller retargets the open dialog', (tester) async {
    final controller = await _open(tester);
    controller.value = SettingsCategory.diagnostics;
    await tester.pumpAndSettle();
    expect(find.text('root diagnostics'), findsOneWidget);
  });

  testWidgets('sizes to 880x600 with room, fills a small window',
      (tester) async {
    await _open(tester);
    expect(tester.getSize(find.byKey(const Key('settings-dialog'))),
        const Size(880, 600));
    await tester.tap(find.byKey(const Key('settings-dialog-close')));
    await tester.pumpAndSettle();

    await _open(tester, size: const Size(600, 400));
    expect(tester.getSize(find.byKey(const Key('settings-dialog'))),
        const Size(600, 400));
    expect(
        find.byKey(const Key('settings-category-label-playback')), findsNothing,
        reason: 'the sidebar collapses to icons');
  });
}
