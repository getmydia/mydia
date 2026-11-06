// HorizontalRail remembers its place: entering a rail vertically lands on the
// card that last had focus in it, whatever the other rail's scroll position,
// and a rail whose items are reordered returns to the same item by id.
//
// Two real HorizontalRails stacked in a column under the policy the shell's
// content region installs (RegionTraversalPolicy routing every move through
// FocusMemory.requestFocus). Each card is a bare `Focus` labelled with its item
// id, so `focused()` reads the id back.
//
// Requires --dart-define=MYDIA_FORCE_TV=true.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/focus/focus_memory.dart';
import 'package:player/core/focus/region_traversal_policy.dart';
import 'package:player/core/player/input_capabilities.dart';
import 'package:player/presentation/widgets/horizontal_rail.dart';

const double _cardWidth = 220;
const double _railHeight = 300;

List<String> _ids(String rail, [int count = 14]) =>
    [for (var i = 0; i < count; i++) '$rail-$i'];

void main() {
  final skipReason = InputCapabilities.directionalPrimary
      ? false
      : 'requires --dart-define=MYDIA_FORCE_TV=true to force '
          'InputCapabilities.directionalPrimary; CI runs it in the '
          '"Run television-tier tests" step.';

  String focused() => FocusManager.instance.primaryFocus?.debugLabel ?? '';

  FocusNode nodeFor(String id) => FocusManager.instance.rootScope.descendants
      .singleWhere((n) => n.debugLabel == id);

  Future<void> press(WidgetTester tester, LogicalKeyboardKey key) async {
    await tester.sendKeyEvent(key);
    await tester.pumpAndSettle();
  }

  Future<void> focus(WidgetTester tester, String id) async {
    nodeFor(id).requestFocus();
    await tester.pumpAndSettle();
    expect(focused(), id);
  }

  /// The rail keyed [key]'s own scroll position; HorizontalRail owns its
  /// controller, so the test reaches it through the Scrollable it builds.
  ScrollPosition railPosition(WidgetTester tester, Key key) => tester
      .state<ScrollableState>(
        find.descendant(of: find.byKey(key), matching: find.byType(Scrollable)),
      )
      .position;

  group('HorizontalRail focus memory (requires MYDIA_FORCE_TV=true)', () {
    Widget rail(String name, List<String> ids, {bool withIds = true}) {
      return HorizontalRail(
        key: ValueKey('rail-$name'),
        itemCount: ids.length,
        height: _railHeight,
        leftFadeKey: ValueKey('$name-left-fade'),
        rightFadeKey: ValueKey('$name-right-fade'),
        itemId: withIds ? (i) => ids[i] : null,
        itemBuilder: (context, i) => Focus(
          debugLabel: ids[i],
          child: const SizedBox(width: _cardWidth, height: _railHeight),
        ),
      );
    }

    Future<void> pumpRails(
      WidgetTester tester, {
      required List<String> a,
      required List<String> b,
      bool withIds = true,
    }) async {
      tester.view.physicalSize = const Size(1920, 1080);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: FocusTraversalGroup(
              policy: RegionTraversalPolicy(
                requestFocusCallback: FocusMemory.requestFocus,
              ),
              child: FocusScope(
                child: Column(
                  children: [
                    rail('a', a, withIds: withIds),
                    rail('b', b, withIds: withIds),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets(
      'down then up returns to the card that left, after the other rail '
      'was scrolled to its end',
      (tester) async {
        // No itemId: the rail falls back to the index, which is still enough
        // to remember a place in a list that did not change.
        await pumpRails(tester, a: _ids('a'), b: _ids('b'), withIds: false);
        await focus(tester, 'a-5');

        final b = railPosition(tester, const ValueKey('rail-b'));
        b.jumpTo(b.maxScrollExtent);
        await tester.pumpAndSettle();

        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), startsWith('b-'));
        // Moving along rail B breaks Flutter's own up/down history, so the
        // press below can only reach a-5 through the rail's memory.
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(focused(), startsWith('b-'));

        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), 'a-5');
      },
    );

    testWidgets(
      'a reordered rail returns to the remembered item by id',
      (tester) async {
        await pumpRails(tester, a: _ids('a'), b: _ids('b'));
        await focus(tester, 'a-5');
        await press(tester, LogicalKeyboardKey.arrowDown);
        expect(focused(), startsWith('b-'));

        // a-5 moves to the front, the way Continue Watching reorders.
        final reordered = _ids('a')..remove('a-5');
        reordered.insert(0, 'a-5');
        await pumpRails(tester, a: reordered, b: _ids('b'));
        await press(tester, LogicalKeyboardKey.arrowRight);
        expect(focused(), startsWith('b-'));

        await press(tester, LogicalKeyboardKey.arrowUp);
        expect(focused(), 'a-5');
      },
    );
  }, skip: skipReason);
}
