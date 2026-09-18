import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/toast/toast_obstruction.dart';
import 'package:player/presentation/widgets/toast/toaster.dart';

import '../../../test_utils/toast_harness.dart';

final _pill = find.byKey(const Key('toast-pill'));
const _body = Key('body');

Future<void> _pump(WidgetTester tester, Widget body) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: toastLayerBuilder,
    home: Scaffold(body: body),
  ));
}

Future<Rect> _showAndMeasure(WidgetTester tester, {Key from = _body}) async {
  showToast(tester.element(find.byKey(from)), 'Saved');
  await tester.pumpAndSettle();
  return tester.getRect(_pill);
}

Widget _bottomBar(double height, {Key? key, bool active = true}) => Align(
      alignment: Alignment.bottomCenter,
      child: ToastObstruction(
        key: key,
        edge: ToastEdge.bottom,
        active: active,
        child: SizedBox(width: 400, height: height),
      ),
    );

void main() {
  testWidgets('a left obstruction moves the pill into the space right of it',
      (tester) async {
    await _pump(
      tester,
      const Row(children: [
        ToastObstruction(
          edge: ToastEdge.left,
          child: SizedBox(width: 260, height: 900),
        ),
        Expanded(child: SizedBox.expand(key: _body)),
      ]),
    );
    final pill = await _showAndMeasure(tester);
    expect(pill.left, greaterThanOrEqualTo(260 + 16));
    expect(pill.center.dx, closeTo((260 + 16 + 1400 - 16) / 2, 0.5));
  });

  testWidgets('the pill sits 16px above the tallest bottom obstruction',
      (tester) async {
    await _pump(
      tester,
      Stack(children: [
        const SizedBox.expand(key: _body),
        _bottomBar(83),
        const Align(
          alignment: Alignment.bottomLeft,
          child: ToastObstruction(
            edge: ToastEdge.bottom,
            child: SizedBox(width: 100, height: 40),
          ),
        ),
      ]),
    );
    final pill = await _showAndMeasure(tester);
    expect(pill.bottom, closeTo(900 - 83 - 16, 0.5));
  });

  testWidgets('a disabled TickerMode withdraws the claim', (tester) async {
    final onScreen = ValueNotifier(true);
    addTearDown(onScreen.dispose);
    await _pump(
      tester,
      Stack(children: [
        const SizedBox.expand(key: _body),
        ValueListenableBuilder<bool>(
          valueListenable: onScreen,
          builder: (context, enabled, _) =>
              TickerMode(enabled: enabled, child: _bottomBar(200)),
        ),
      ]),
    );
    expect((await _showAndMeasure(tester)).bottom, closeTo(900 - 216, 0.5));

    onScreen.value = false;
    await tester.pumpAndSettle();
    expect(tester.getRect(_pill).bottom, closeTo(900 - 24, 0.5));

    onScreen.value = true;
    await tester.pumpAndSettle();
    expect(tester.getRect(_pill).bottom, closeTo(900 - 216, 0.5));
  });

  testWidgets('active: false withdraws the claim and true restores it',
      (tester) async {
    final active = ValueNotifier(true);
    addTearDown(active.dispose);
    await _pump(
      tester,
      Stack(children: [
        const SizedBox.expand(key: _body),
        ValueListenableBuilder<bool>(
          valueListenable: active,
          builder: (context, value, _) => _bottomBar(120, active: value),
        ),
      ]),
    );
    expect((await _showAndMeasure(tester)).bottom, closeTo(900 - 136, 0.5));

    active.value = false;
    await tester.pumpAndSettle();
    expect(tester.getRect(_pill).bottom, closeTo(900 - 24, 0.5));

    active.value = true;
    await tester.pumpAndSettle();
    expect(tester.getRect(_pill).bottom, closeTo(900 - 136, 0.5));
  });

  testWidgets('resizing an obstruction moves the pill', (tester) async {
    final height = ValueNotifier<double>(83);
    addTearDown(height.dispose);
    await _pump(
      tester,
      Stack(children: [
        const SizedBox.expand(key: _body),
        ValueListenableBuilder<double>(
          valueListenable: height,
          builder: (context, value, _) => _bottomBar(value),
        ),
      ]),
    );
    expect((await _showAndMeasure(tester)).bottom, closeTo(900 - 99, 0.5));

    height.value = 150;
    await tester.pumpAndSettle();
    expect(tester.getRect(_pill).bottom, closeTo(900 - 166, 0.5));
  });

  testWidgets("a disposed obstruction leaves its replacement's claim",
      (tester) async {
    final useB = ValueNotifier(false);
    addTearDown(useB.dispose);
    await _pump(
      tester,
      Stack(children: [
        const SizedBox.expand(key: _body),
        ValueListenableBuilder<bool>(
          valueListenable: useB,
          builder: (context, b, _) => b
              ? _bottomBar(150, key: const ValueKey('b'))
              : _bottomBar(100, key: const ValueKey('a')),
        ),
      ]),
    );
    expect((await _showAndMeasure(tester)).bottom, closeTo(900 - 116, 0.5));

    useB.value = true;
    await tester.pumpAndSettle();
    expect(tester.getRect(_pill).bottom, closeTo(900 - 166, 0.5));
  });

  testWidgets('a route covered by an opaque route stops counting',
      (tester) async {
    await _pump(
      tester,
      Stack(children: [
        const SizedBox.expand(key: _body),
        _bottomBar(200),
      ]),
    );
    Navigator.of(tester.element(find.byKey(_body))).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const Scaffold(body: SizedBox.expand(key: Key('covering'))),
      ),
    );
    await tester.pumpAndSettle();
    final covered = await _showAndMeasure(tester, from: const Key('covering'));
    expect(covered.bottom, closeTo(900 - 24, 0.5));

    Navigator.of(tester.element(find.byKey(const Key('covering')))).pop();
    await tester.pumpAndSettle();
    expect(tester.getRect(_pill).bottom, closeTo(900 - 216, 0.5));
  });

  testWidgets('a dialog does not hide what is under it', (tester) async {
    await _pump(
      tester,
      Stack(children: [
        const SizedBox.expand(key: _body),
        _bottomBar(200),
      ]),
    );
    showDialog<void>(
      context: tester.element(find.byKey(_body)),
      builder: (_) => const AlertDialog(content: SizedBox(key: Key('dialog'))),
    );
    await tester.pumpAndSettle();
    final pill = await _showAndMeasure(tester, from: const Key('dialog'));
    expect(pill.bottom, closeTo(900 - 216, 0.5));
  });

  testWidgets('without a ToastLayer it is inert', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: ToastObstruction(
        edge: ToastEdge.bottom,
        child: SizedBox(height: 50),
      ),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
