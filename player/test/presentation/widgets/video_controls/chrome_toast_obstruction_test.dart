import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/presentation/widgets/toast/toaster.dart';
import 'package:player/presentation/widgets/video_controls/playback_chrome.dart';

import '../../../test_utils/toast_harness.dart';

final _pill = find.byKey(const Key('toast-pill'));
const _body = Key('body');

Widget _panel() => const Align(
      alignment: Alignment.bottomCenter,
      child: ChromeToastObstruction(child: SizedBox(width: 600, height: 120)),
    );

Future<void> _pump(WidgetTester tester, Widget body) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MaterialApp(
    builder: toastLayerBuilder,
    home: Scaffold(
      body: Stack(children: [const SizedBox.expand(key: _body), body]),
    ),
  ));
}

void main() {
  testWidgets('withdraws as the chrome starts hiding, returns as it shows',
      (tester) async {
    final chrome = AnimationController(
      vsync: const TestVSync(),
      duration: const Duration(milliseconds: 200),
      value: 1,
    );
    addTearDown(chrome.dispose);
    await _pump(tester, ChromeAnimation(animation: chrome, child: _panel()));

    showToast(tester.element(find.byKey(_body)), 'Saved');
    await tester.pumpAndSettle();
    expect(tester.getRect(_pill).bottom, closeTo(900 - 136, 0.5));

    chrome.reverse();
    await tester.pumpAndSettle();
    expect(tester.getRect(_pill).bottom, closeTo(900 - 24, 0.5));

    chrome.forward();
    await tester.pumpAndSettle();
    expect(tester.getRect(_pill).bottom, closeTo(900 - 136, 0.5));
  });

  testWidgets('counts when there is no chrome animation above it',
      (tester) async {
    await _pump(tester, _panel());
    showToast(tester.element(find.byKey(_body)), 'Saved');
    await tester.pumpAndSettle();
    expect(tester.getRect(_pill).bottom, closeTo(900 - 136, 0.5));
  });
}
