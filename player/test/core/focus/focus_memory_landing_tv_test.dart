// A page names where focus lands: a landing FocusMemoryRegion takes focus
// when its page opens, including once a page that is still loading builds
// its first item, and a viewer who has already moved inside the page keeps
// what they chose.
//
// Each page is a route of its own, pushed over a first page holding the
// focus the way a card on the previous page or a sidebar row does. Every
// focusable is a bare `Focus` labelled with its id, so `focused()` reads the
// id back.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/focus/focus_memory.dart';
import 'package:player/core/player/input_capabilities.dart';

void main() {
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
          'InputCapabilities.directionalPrimary; CI runs it in the '
          '"Run television-tier tests" step.';

  String focused() => FocusManager.instance.primaryFocus?.debugLabel ?? '';

  Widget box(String id, {bool autofocus = false}) => Focus(
        debugLabel: id,
        autofocus: autofocus,
        child: const SizedBox(width: 100, height: 80),
      );

  Widget grid(List<String> ids, {bool landing = true}) => FocusMemoryRegion(
        landing: landing,
        debugLabel: 'grid',
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (i, id) in ids.indexed)
              FocusMemoryItem(id: id, index: i, child: box(id)),
          ],
        ),
      );

  /// A page with a top control above a grid of [items], or of whatever
  /// [items] holds by the time it rebuilds.
  Widget page(
    ValueListenable<List<String>> items, {
    bool autofocusTop = false,
    bool landing = true,
  }) =>
      Column(
        children: [
          box('top', autofocus: autofocusTop),
          ValueListenableBuilder<List<String>>(
            valueListenable: items,
            builder: (_, ids, __) => grid(ids, landing: landing),
          ),
        ],
      );

  late GlobalKey<NavigatorState> navigator;

  Future<void> pumpFirstPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1920, 1080);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    navigator = GlobalKey<NavigatorState>();
    // As main.dart does at startup.
    FocusMemory.listenForPresses();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Column(children: [box('previous')]),
      ),
    );
    FocusManager.instance.rootScope.descendants
        .singleWhere((n) => n.debugLabel == 'previous')
        .requestFocus();
    await tester.pumpAndSettle();
    expect(focused(), 'previous');
  }

  Future<void> open(WidgetTester tester, Widget child) async {
    unawaited(navigator.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => child),
    ));
    await tester.pumpAndSettle();
  }

  group('FocusMemoryRegion.landing (requires MYDIA_FORCE_TV=true)', () {
    testWidgets('opening a page lands on its landing region', (tester) async {
      await pumpFirstPage(tester);
      await open(tester, page(ValueNotifier(['a', 'b', 'c'])));
      expect(focused(), 'a');
    });

    testWidgets('a page without a landing region keeps today\'s behaviour',
        (tester) async {
      await pumpFirstPage(tester);
      await open(tester, page(ValueNotifier(['a', 'b']), landing: false));
      expect(focused(), isNot('a'));
    });

    testWidgets('the landing region wins over a control that autofocused',
        (tester) async {
      await pumpFirstPage(tester);
      await open(
        tester,
        page(ValueNotifier(['a', 'b']), autofocusTop: true),
      );
      expect(focused(), 'a');
    });

    testWidgets('a grid still loading lands once its first item is built',
        (tester) async {
      await pumpFirstPage(tester);
      final items = ValueNotifier<List<String>>([]);
      addTearDown(items.dispose);
      await open(tester, page(items));
      expect(focused(), isNot('a'));

      items.value = ['a', 'b'];
      await tester.pumpAndSettle();
      expect(focused(), 'a');
    });

    testWidgets(
        'a viewer who moved inside the page while it loaded keeps their place',
        (tester) async {
      await pumpFirstPage(tester);
      final items = ValueNotifier<List<String>>([]);
      addTearDown(items.dispose);
      await open(tester, page(items, autofocusTop: true));
      expect(focused(), 'top');

      // Any press inside the page is a choice; the grid arriving later must
      // not take focus back from it.
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(focused(), 'top');

      items.value = ['a', 'b'];
      await tester.pumpAndSettle();
      expect(focused(), 'top');
    });

    testWidgets(
        'a landing region rebuilt on the page the viewer is on does not move '
        'them', (tester) async {
      await pumpFirstPage(tester);
      final showGrid = ValueNotifier(true);
      addTearDown(showGrid.dispose);
      await open(
        tester,
        Column(
          children: [
            box('toggle'),
            ValueListenableBuilder<bool>(
              valueListenable: showGrid,
              builder: (_, grid, __) => KeyedSubtree(
                key: ValueKey(grid),
                child: FocusMemoryRegion(
                  landing: true,
                  child: FocusMemoryItem(
                    id: 'x',
                    index: 0,
                    child: box(grid ? 'grid-a' : 'list-a'),
                  ),
                ),
              ),
            ),
          ],
        ),
      );
      expect(focused(), 'grid-a');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(focused(), 'toggle');

      // What OK on the toggle does.
      showGrid.value = false;
      await tester.pumpAndSettle();
      expect(focused(), 'toggle');
    });

    testWidgets(
        'a press on the page before the landing region is built keeps the '
        'viewer\'s place', (tester) async {
      await pumpFirstPage(tester);
      final loaded = ValueNotifier(false);
      addTearDown(loaded.dispose);
      await open(
        tester,
        Column(
          children: [
            box('top', autofocus: true),
            box('next'),
            ValueListenableBuilder<bool>(
              valueListenable: loaded,
              builder: (_, done, __) =>
                  done ? grid(['a', 'b']) : const SizedBox.shrink(),
            ),
          ],
        ),
      );
      expect(focused(), 'top');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(focused(), 'next');

      loaded.value = true;
      await tester.pumpAndSettle();
      expect(focused(), 'next');
    });

    testWidgets('a page covered by another before it is ready does not land',
        (tester) async {
      await pumpFirstPage(tester);
      final items = ValueNotifier<List<String>>([]);
      addTearDown(items.dispose);
      await open(tester, page(items));
      await open(tester, Column(children: [box('above', autofocus: true)]));
      expect(focused(), 'above');

      items.value = ['a', 'b'];
      await tester.pumpAndSettle();
      expect(focused(), 'above');
    });

    testWidgets(
        'a landing that became ready under a dialog lands once it '
        'closes', (tester) async {
      await pumpFirstPage(tester);
      final items = ValueNotifier<List<String>>([]);
      addTearDown(items.dispose);
      await open(tester, page(items));
      unawaited(showDialog<void>(
        context: navigator.currentContext!,
        builder: (_) => Center(child: box('dialog', autofocus: true)),
      ));
      await tester.pumpAndSettle();
      expect(focused(), 'dialog');

      items.value = ['a', 'b'];
      await tester.pumpAndSettle();
      expect(focused(), 'dialog');

      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(focused(), 'a');
    });

    testWidgets('initialId picks the item a landing waits for', (tester) async {
      await pumpFirstPage(tester);
      await open(
        tester,
        FocusMemoryRegion(
          landing: true,
          initialId: 'b',
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Never focusable: a landing that waited for the lowest index
              // would wait forever.
              const FocusMemoryItem(
                id: 'a',
                index: 0,
                child: Focus(
                  debugLabel: 'a',
                  canRequestFocus: false,
                  child: SizedBox(width: 100, height: 80),
                ),
              ),
              FocusMemoryItem(id: 'b', index: 1, child: box('b')),
            ],
          ),
        ),
      );
      expect(focused(), 'b');
    });

    testWidgets('a region no longer marked as landing stops its claim',
        (tester) async {
      await pumpFirstPage(tester);
      final items = ValueNotifier<List<String>>([]);
      final landing = ValueNotifier(true);
      addTearDown(items.dispose);
      addTearDown(landing.dispose);
      await open(
        tester,
        ValueListenableBuilder<bool>(
          valueListenable: landing,
          builder: (_, isLanding, __) => ValueListenableBuilder<List<String>>(
            valueListenable: items,
            builder: (_, ids, __) => grid(ids, landing: isLanding),
          ),
        ),
      );
      landing.value = false;
      await tester.pumpAndSettle();

      items.value = ['a', 'b'];
      await tester.pumpAndSettle();
      expect(focused(), isNot('a'));
      expect(
        FocusMemory.landingTargetWithin(FocusManager.instance.rootScope),
        isNull,
      );
    });

    testWidgets('lands only once: returning to the page does not re-land',
        (tester) async {
      await pumpFirstPage(tester);
      await open(tester, page(ValueNotifier(['a', 'b'])));
      FocusManager.instance.rootScope.descendants
          .singleWhere((n) => n.debugLabel == 'top')
          .requestFocus();
      await tester.pumpAndSettle();

      await open(tester, Column(children: [box('above', autofocus: true)]));
      expect(focused(), 'above');
      navigator.currentState!.pop();
      await tester.pumpAndSettle();
      expect(focused(), 'top');
    });

    testWidgets(
        'claimLanding focuses the page\'s landing region, ignoring memory',
        (tester) async {
      await pumpFirstPage(tester);
      await open(tester, page(ValueNotifier(['play', 'version'])));
      FocusManager.instance.rootScope.descendants
          .singleWhere((n) => n.debugLabel == 'version')
          .requestFocus();
      await tester.pumpAndSettle();
      final top = FocusManager.instance.rootScope.descendants
          .singleWhere((n) => n.debugLabel == 'top');
      top.requestFocus();
      await tester.pumpAndSettle();

      FocusMemory.claimLanding(top.context!);
      await tester.pumpAndSettle();
      expect(focused(), 'play');
    });

    testWidgets('landingTargetWithin finds the landing item under a scope',
        (tester) async {
      await pumpFirstPage(tester);
      await open(tester, page(ValueNotifier(['a', 'b'])));
      final target = FocusMemory.landingTargetWithin(
        FocusManager.instance.rootScope,
      );
      expect(target?.debugLabel, 'a');
    });
  }, skip: skipReason);
}
