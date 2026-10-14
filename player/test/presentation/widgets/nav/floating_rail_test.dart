import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/layout/breakpoints.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/core/theme/ambient_tint/ambient_tint_colors.dart';
import 'package:player/core/theme/colors.dart';
import 'package:player/presentation/widgets/nav/floating_rail.dart';
import 'package:player/presentation/widgets/nav/sidebar_content.dart';

import '../../screens/sources/fake_capable_source.dart';
import '../../screens/sources/fake_media_source.dart';

class _MydiaLike extends FakeCapableSource {
  @override
  Set<SourceCapability> get capabilities =>
      {...super.capabilities, SourceCapability.continueWatching};
}

const _railKey = Key('floating-rail');
const _scrimKey = Key('rail-scrim');

double _railWidth(WidgetTester tester) =>
    tester.getSize(find.byKey(_railKey)).width;

Future<InMemorySidebarLayoutStore> _pumpRail(
  WidgetTester tester, {
  FocusNode? rowNode,
  FocusNode? contentNode,
  VoidCallback? onExitRequested,
  ValueChanged<String>? onNavigate,
  bool highContrast = false,
  bool disableAnimations = false,
  bool pinned = false,
  bool showBackToMydia = false,
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final store = InMemorySidebarLayoutStore();
  if (pinned) await store.saveRailPinned(true);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sidebarLayoutStoreProvider.overrideWithValue(store),
        thirdPartySourcesProvider.overrideWithValue(const [fakeSource]),
        switchableSourcesProvider.overrideWithValue(const [fakeSource]),
        hasMydiaProvider.overrideWithValue(true),
        mediaSourceProvider(fakeSourceId).overrideWithValue(_MydiaLike()),
      ],
      child: MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            highContrast: highContrast,
            disableAnimations: disableAnimations,
          ),
          child: child!,
        ),
        home: Scaffold(
          body: Stack(
            children: [
              Positioned.fill(
                child: Padding(
                  padding: EdgeInsets.only(
                    left: Breakpoints.railContentInset(pinned: false),
                  ),
                  child: Focus(
                    focusNode: contentNode,
                    child: const ColoredBox(
                      key: Key('content'),
                      color: Colors.black,
                    ),
                  ),
                ),
              ),
              Positioned.fill(
                child: FloatingRail(
                  location: '/',
                  onNavigate: onNavigate ?? (_) {},
                  isOffline: false,
                  showBackToMydia: showBackToMydia,
                  selectedRowFocusNode: rowNode,
                  onExitRequested: onExitRequested,
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}

/// The animated opacity value (not the target) of the fade above [finder].
double _fadeValue(WidgetTester tester, Finder fade) => tester
    .widget<FadeTransition>(
      find.descendant(of: fade, matching: find.byType(FadeTransition)).first,
    )
    .opacity
    .value;

double _labelOpacity(WidgetTester tester, String text) => _fadeValue(
      tester,
      find.ancestor(
          of: find.text(text), matching: find.byType(AnimatedOpacity)),
    );

double _scrimOpacity(WidgetTester tester) =>
    _fadeValue(tester, find.byKey(const Key('rail-scrim-fade')));

/// The focus node a button owns: the nearest one enclosing [inner], a widget
/// inside the button (`Focus.of` on the button itself would find a parent's).
FocusNode _buttonNode(WidgetTester tester, Finder button, Finder inner) =>
    Focus.of(
      tester.element(find.descendant(of: button, matching: inner).first),
    );

/// The icon of every entry the rail must keep still, by name.
Map<String, Finder> _railIcons() {
  Finder inRow(String id) => find
      .descendant(
        of: find.byKey(ValueKey('sidebar-row-$id')),
        matching: find.byType(Icon),
      )
      .first;
  return {
    'server switcher': find.byKey(const ValueKey('source-switcher-compact')),
    'back to mydia': find.byIcon(Icons.arrow_back_rounded),
    'first row': inRow('search'),
    'middle row': inRow('movies'),
    'settings': inRow('settings'),
    'new filter': inRow('new-filter'),
  };
}

Map<String, Rect> _rects(WidgetTester tester, Map<String, Finder> icons) =>
    {for (final e in icons.entries) e.key: tester.getRect(e.value)};

void _expectSameRects(
  Map<String, Rect> expected,
  Map<String, Rect> actual,
  String when,
) {
  for (final e in expected.entries) {
    final got = actual[e.key]!;
    expect(
      (got.left - e.value.left).abs() < 0.5 &&
          (got.top - e.value.top).abs() < 0.5 &&
          (got.width - e.value.width).abs() < 0.5 &&
          (got.height - e.value.height).abs() < 0.5,
      isTrue,
      reason: '${e.key} moved $when: ${e.value} -> $got',
    );
  }
}

/// Pumps [frames] 16ms frames, checking every one for exceptions and calling
/// [onFrame] with the frame's index.
Future<void> _pumpFrames(
  WidgetTester tester,
  int frames, {
  void Function(int frame)? onFrame,
}) async {
  for (var i = 0; i < frames; i++) {
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.takeException(), isNull, reason: 'exception in frame $i');
    onFrame?.call(i);
  }
}

double _contrast(Color a, Color b) {
  final la = a.computeLuminance();
  final lb = b.computeLuminance();
  final hi = la > lb ? la : lb;
  final lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  testWidgets('collapsed at rest: 72 wide, inset 16', (tester) async {
    await _pumpRail(tester);
    final rect = tester.getRect(find.byKey(_railKey));
    expect(rect.left, 16);
    expect(rect.top, 16);
    expect(rect.width, 72);
    expect(find.byKey(_scrimKey), findsNothing);
  });

  testWidgets('hover held 200ms expands over content with a scrim',
      (tester) async {
    await _pumpRail(tester);
    final contentBefore = tester.getRect(find.byKey(const Key('content')));
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(40, 300));
    await tester.pump(const Duration(milliseconds: 150));
    expect(_railWidth(tester), 72);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(_railWidth(tester), 272);
    expect(find.byKey(_scrimKey), findsOneWidget);
    expect(tester.getRect(find.byKey(const Key('content'))), contentBefore);
    await gesture.moveTo(const Offset(900, 300));
    await tester.pumpAndSettle();
    expect(_railWidth(tester), 72);
  });

  testWidgets('focus entering the rail expands it; leaving collapses',
      (tester) async {
    final row = FocusNode(debugLabel: 'row');
    final content = FocusNode(debugLabel: 'content');
    addTearDown(row.dispose);
    addTearDown(content.dispose);
    await _pumpRail(tester, rowNode: row, contentNode: content);

    row.requestFocus();
    await tester.pumpAndSettle();
    expect(_railWidth(tester), 272);

    content.requestFocus();
    await tester.pumpAndSettle();
    expect(_railWidth(tester), 72);
  });

  testWidgets('Escape collapses and asks the shell for content focus',
      (tester) async {
    final row = FocusNode(debugLabel: 'row');
    addTearDown(row.dispose);
    var exits = 0;
    await _pumpRail(tester, rowNode: row, onExitRequested: () => exits++);

    row.requestFocus();
    await tester.pumpAndSettle();
    expect(_railWidth(tester), 272);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(exits, 1);
    expect(_railWidth(tester), 72);
    expect(find.byKey(_scrimKey), findsNothing);
  });

  testWidgets('pin keeps it expanded without a scrim and persists',
      (tester) async {
    final store = await _pumpRail(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(40, 300));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();
    expect(_railWidth(tester), 272);

    await tester.tap(find.byKey(const Key('rail-pin')));
    await tester.pumpAndSettle();
    await gesture.moveTo(const Offset(900, 300));
    await tester.pumpAndSettle();

    expect(_railWidth(tester), 272);
    expect(find.byKey(_scrimKey), findsNothing);
    expect(store.railPinned, isTrue);
  });

  testWidgets('tapping the scrim collapses the rail', (tester) async {
    final row = FocusNode(debugLabel: 'row');
    addTearDown(row.dispose);
    await _pumpRail(tester, rowNode: row);
    row.requestFocus();
    await tester.pumpAndSettle();
    expect(find.byKey(_scrimKey), findsOneWidget);

    await tester.tapAt(const Offset(900, 400));
    await tester.pumpAndSettle();
    expect(find.byKey(_scrimKey), findsNothing);
    expect(_railWidth(tester), 72);
  });

  testWidgets('reduced motion expands instantly', (tester) async {
    final row = FocusNode(debugLabel: 'row');
    addTearDown(row.dispose);
    await _pumpRail(tester, rowNode: row, disableAnimations: true);

    row.requestFocus();
    // Focus changes land in a microtask, then one frame builds the result.
    await tester.idle();
    await tester.pump();
    expect(_railWidth(tester), 272);
  });

  testWidgets('high contrast raises the scrim to 70%', (tester) async {
    final row = FocusNode(debugLabel: 'row');
    addTearDown(row.dispose);
    await _pumpRail(tester, rowNode: row, highContrast: true);

    row.requestFocus();
    await tester.pumpAndSettle();
    final scrim = tester.widget<ColoredBox>(find.byKey(_scrimKey));
    expect(scrim.color.a, closeTo(0.7, 0.01));
  });

  testWidgets('normal contrast scrim is 55%', (tester) async {
    final row = FocusNode(debugLabel: 'row');
    addTearDown(row.dispose);
    await _pumpRail(tester, rowNode: row);

    row.requestFocus();
    await tester.pumpAndSettle();
    final scrim = tester.widget<ColoredBox>(find.byKey(_scrimKey));
    expect(scrim.color.a, closeTo(0.55, 0.01));
  });

  testWidgets('moving out before 200ms cancels the hover expansion',
      (tester) async {
    await _pumpRail(tester);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(40, 300));
    await tester.pump(const Duration(milliseconds: 100));
    await gesture.moveTo(const Offset(900, 300));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(_railWidth(tester), 72);
    expect(find.byKey(_scrimKey), findsNothing);
  });

  testWidgets('pinned, hovered, then unpinned keeps expanded with labels',
      (tester) async {
    await _pumpRail(tester, pinned: true);
    expect(_railWidth(tester), 272);
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: const Offset(40, 300));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('rail-pin')));
    await tester.pumpAndSettle();

    expect(_railWidth(tester), 272);
    expect(
      tester
          .widget<SidebarContent>(find.byType(SidebarContent))
          .railLabelsVisible,
      isTrue,
    );
    expect(_labelOpacity(tester, 'Movies'), 1);
    expect(find.byKey(_scrimKey), findsOneWidget);
  });

  testWidgets(
      'pinned then unpinned with pointer away collapses and exits '
      'edit mode', (tester) async {
    await _pumpRail(tester, pinned: true);
    final container =
        ProviderScope.containerOf(tester.element(find.byType(FloatingRail)));
    container.read(sidebarEditModeProvider.notifier).toggle();
    expect(container.read(sidebarEditModeProvider), isTrue);

    await tester.tap(find.byKey(const Key('rail-pin')));
    await tester.pumpAndSettle();

    expect(_railWidth(tester), 72);
    expect(find.byKey(_scrimKey), findsNothing);
    expect(container.read(sidebarEditModeProvider), isFalse);
  });

  testWidgets('navigating collapses an unpinned rail', (tester) async {
    final row = FocusNode(debugLabel: 'row');
    addTearDown(row.dispose);
    final routes = <String>[];
    await _pumpRail(tester, rowNode: row, onNavigate: routes.add);
    row.requestFocus();
    await tester.pumpAndSettle();
    expect(_railWidth(tester), 272);

    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    expect(routes, hasLength(1));
    expect(_railWidth(tester), 72);
  });

  testWidgets('navigating does not collapse a pinned rail', (tester) async {
    final routes = <String>[];
    await _pumpRail(tester, pinned: true, onNavigate: routes.add);

    await tester.tap(find.text('Movies'));
    await tester.pumpAndSettle();
    expect(routes, hasLength(1));
    expect(_railWidth(tester), 272);
  });

  group('one geometry, only width and label opacity animate', () {
    testWidgets('icons never move while the rail expands and collapses',
        (tester) async {
      await _pumpRail(tester, showBackToMydia: true);
      final icons = _railIcons();
      final collapsed = _rects(tester, icons);
      expect(_railWidth(tester), 72);
      // Centred in the collapsed rail.
      final rail = tester.getRect(find.byKey(_railKey));
      for (final e in collapsed.entries) {
        expect(e.value.center.dx, closeTo(rail.center.dx, 0.5), reason: e.key);
      }

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(40, 300));
      await _pumpFrames(
        tester,
        40,
        onFrame: (_) =>
            _expectSameRects(collapsed, _rects(tester, icons), 'expanding'),
      );
      await tester.pumpAndSettle();
      expect(_railWidth(tester), 272);
      _expectSameRects(collapsed, _rects(tester, icons), 'once expanded');

      await gesture.moveTo(const Offset(900, 300));
      await _pumpFrames(
        tester,
        25,
        onFrame: (_) =>
            _expectSameRects(collapsed, _rects(tester, icons), 'collapsing'),
      );
      await tester.pumpAndSettle();
      expect(_railWidth(tester), 72);
      _expectSameRects(collapsed, _rects(tester, icons), 'once collapsed');
    });

    testWidgets('no overflow at 72px or mid-animation, Back to Mydia shown',
        (tester) async {
      await _pumpRail(tester, showBackToMydia: true);
      expect(tester.takeException(), isNull);
      expect(find.text('Back to Mydia'), findsOneWidget);
      expect(find.byTooltip('Back to Mydia'), findsOneWidget);

      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(40, 300));
      await _pumpFrames(tester, 30);
      await gesture.moveTo(const Offset(900, 300));
      await _pumpFrames(tester, 20);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });

    testWidgets('labels are invisible collapsed and opaque expanded',
        (tester) async {
      final row = FocusNode(debugLabel: 'row');
      addTearDown(row.dispose);
      await _pumpRail(tester, rowNode: row);
      expect(_labelOpacity(tester, 'Movies'), 0);
      expect(_labelOpacity(tester, 'Settings'), 0);

      row.requestFocus();
      await tester.pumpAndSettle();
      expect(_labelOpacity(tester, 'Movies'), 1);
      expect(_labelOpacity(tester, 'Settings'), 1);
    });

    testWidgets('labels fade in late and out fast, not all at once',
        (tester) async {
      final row = FocusNode(debugLabel: 'row');
      addTearDown(row.dispose);
      await _pumpRail(tester, rowNode: row);

      row.requestFocus();
      await tester.idle();
      await tester.pump();
      // Early in the width animation the labels have not started to show.
      await tester.pump(const Duration(milliseconds: 48));
      final early = _labelOpacity(tester, 'Movies');
      await tester.pump(const Duration(milliseconds: 64));
      final mid = _labelOpacity(tester, 'Movies');
      expect(early, lessThan(0.1));
      expect(mid, inExclusiveRange(0.0, 1.0));
      await tester.pumpAndSettle();
      expect(_labelOpacity(tester, 'Movies'), 1);

      // Collapse: gone well before the 200ms width animation finishes.
      row.unfocus();
      await tester.idle();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 110));
      expect(_labelOpacity(tester, 'Movies'), 0);
      expect(_railWidth(tester), greaterThan(72));
    });

    testWidgets('the scrim fades rather than jumping, inert while hidden',
        (tester) async {
      final row = FocusNode(debugLabel: 'row');
      addTearDown(row.dispose);
      await _pumpRail(tester, rowNode: row);
      expect(_scrimOpacity(tester), 0);
      expect(
        tester
            .widget<IgnorePointer>(find.byKey(const Key('rail-scrim-guard')))
            .ignoring,
        isTrue,
      );

      row.requestFocus();
      await tester.idle();
      await tester.pump();
      final seen = <double>[];
      await _pumpFrames(tester, 6, onFrame: (_) {
        seen.add(_scrimOpacity(tester));
      });
      expect(seen.first, greaterThan(0));
      expect(seen.first, lessThan(1));
      for (var i = 1; i < seen.length; i++) {
        expect(seen[i], greaterThanOrEqualTo(seen[i - 1]));
      }
      expect(
        tester
            .widget<IgnorePointer>(find.byKey(const Key('rail-scrim-guard')))
            .ignoring,
        isFalse,
      );
      await tester.pumpAndSettle();
      expect(_scrimOpacity(tester), 1);

      row.unfocus();
      await tester.idle();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));
      final fading = _scrimOpacity(tester);
      expect(fading, inExclusiveRange(0.0, 1.0));
      await tester.pumpAndSettle();
      expect(_scrimOpacity(tester), 0);
    });

    testWidgets('the footer buttons are inert and unfocusable collapsed',
        (tester) async {
      final store = await _pumpRail(tester);
      const pin = Key('rail-pin');
      const edit = Key('rail-edit');
      FocusNode nodeOf(Key key) =>
          _buttonNode(tester, find.byKey(key), find.byType(Icon));

      expect(nodeOf(pin).canRequestFocus, isFalse);
      expect(nodeOf(edit).canRequestFocus, isFalse);
      await tester.tap(find.byKey(pin), warnIfMissed: false);
      await tester.tap(find.byKey(edit), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(store.railPinned, isFalse);
      final container =
          ProviderScope.containerOf(tester.element(find.byType(FloatingRail)));
      expect(container.read(sidebarEditModeProvider), isFalse);
      // Still reserving room, so nothing above moves.
      expect(tester.getSize(find.byKey(pin)).height, greaterThan(0));
    });

    testWidgets('the footer buttons work once expanded', (tester) async {
      final store = await _pumpRail(tester);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(40, 300));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      final container =
          ProviderScope.containerOf(tester.element(find.byType(FloatingRail)));

      await tester.tap(find.byKey(const Key('rail-edit')));
      await tester.pumpAndSettle();
      expect(container.read(sidebarEditModeProvider), isTrue);
      expect(_railWidth(tester), 272);

      await tester.tap(find.byKey(const Key('rail-pin')));
      await tester.pumpAndSettle();
      expect(store.railPinned, isTrue);
    });

    testWidgets('finishing an edit from the keyboard keeps focus in the rail',
        (tester) async {
      final row = FocusNode(debugLabel: 'row');
      addTearDown(row.dispose);
      await _pumpRail(tester, rowNode: row);
      row.requestFocus();
      await tester.pumpAndSettle();
      expect(_railWidth(tester), 272);

      bool focusInRail() =>
          FocusManager.instance.primaryFocus?.context
              ?.findAncestorWidgetOfExactType<FloatingRail>() !=
          null;
      final container =
          ProviderScope.containerOf(tester.element(find.byType(FloatingRail)));

      // Focus alone (no hover) reaches the footer's edit button and presses it.
      _buttonNode(tester, find.byKey(const Key('rail-edit')), find.byType(Icon))
          .requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(container.read(sidebarEditModeProvider), isTrue);
      expect(_railWidth(tester), 272);
      expect(focusInRail(), isTrue);

      // Move focus to Done and press it.
      _buttonNode(
        tester,
        find.widgetWithText(TextButton, 'Done'),
        find.byType(Text),
      ).requestFocus();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      expect(container.read(sidebarEditModeProvider), isFalse);
      expect(focusInRail(), isTrue);
      expect(_railWidth(tester), 272);
    });

    testWidgets('Done with no earlier focus in the rail does not collapse it',
        (tester) async {
      // Focus history would let Flutter fall back to an earlier node, hiding
      // the defect. Here Done is the only thing ever focused in the rail.
      await _pumpRail(tester);
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: const Offset(40, 300));
      await tester.pump(const Duration(milliseconds: 250));
      await tester.pumpAndSettle();
      final container =
          ProviderScope.containerOf(tester.element(find.byType(FloatingRail)));
      container.read(sidebarEditModeProvider.notifier).toggle();
      await tester.pumpAndSettle();

      _buttonNode(
        tester,
        find.widgetWithText(TextButton, 'Done'),
        find.byType(Text),
      ).requestFocus();
      await tester.pumpAndSettle();
      await gesture.moveTo(const Offset(900, 300));
      await tester.pumpAndSettle();
      expect(_railWidth(tester), 272, reason: 'focus on Done holds it open');

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(container.read(sidebarEditModeProvider), isFalse);
      expect(_railWidth(tester), 272);
      expect(
        FocusManager.instance.primaryFocus?.context
            ?.findAncestorWidgetOfExactType<FloatingRail>(),
        isNotNull,
      );
    });

    testWidgets('reduced motion reaches the final state in one pump',
        (tester) async {
      final row = FocusNode(debugLabel: 'row');
      addTearDown(row.dispose);
      await _pumpRail(tester, rowNode: row, disableAnimations: true);

      row.requestFocus();
      await tester.idle();
      await tester.pump();
      expect(_railWidth(tester), 272);
      expect(_labelOpacity(tester, 'Movies'), 1);
      expect(_scrimOpacity(tester), 1);

      row.unfocus();
      await tester.idle();
      await tester.pump();
      expect(_railWidth(tester), 72);
      expect(_labelOpacity(tester, 'Movies'), 0);
      expect(_scrimOpacity(tester), 0);
    });
  });

  test('expanded fill keeps textSecondary at 4.5:1 over a white backdrop', () {
    final fill = Color.alphaBlend(
      AmbientTintColors.neutral.surface.withValues(alpha: 0.92),
      Colors.white,
    );
    expect(_contrast(AppColors.textSecondary, fill), greaterThanOrEqualTo(4.5));
  });
}
