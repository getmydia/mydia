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
}) async {
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final store = InMemorySidebarLayoutStore();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sidebarLayoutStoreProvider.overrideWithValue(store),
        thirdPartySourcesProvider.overrideWithValue(const [fakeSource]),
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

  test('expanded fill keeps textSecondary at 4.5:1 over a white backdrop', () {
    final fill = Color.alphaBlend(
      AmbientTintColors.neutral.surface.withValues(alpha: 0.92),
      Colors.white,
    );
    expect(_contrast(AppColors.textSecondary, fill), greaterThanOrEqualTo(4.5));
  });
}
