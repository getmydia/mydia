import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/nav/sidebar_edit_bar.dart';
import 'package:player/presentation/widgets/nav/sidebar_edit_sheet.dart';

import '../../screens/sources/fake_media_source.dart';

Future<ProviderContainer> _open(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final container = ProviderContainer(overrides: [
    sidebarLayoutStoreProvider.overrideWithValue(InMemorySidebarLayoutStore()),
    thirdPartySourcesProvider.overrideWithValue(const [fakeSource]),
    hasMydiaProvider.overrideWithValue(true),
    mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
  ]);
  addTearDown(container.dispose);
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => Consumer(
                builder: (context, ref, _) => Column(
                  children: [
                    const Text('second page'),
                    TextButton(
                      onPressed: () => showSidebarEditSheet(
                        context: context,
                        ref: ref,
                        location: '/s/acc1:owner:aa11',
                      ),
                      child: const Text('open'),
                    ),
                  ],
                ),
              ),
            ),
          ),
          child: const Text('push'),
        ),
      ),
    ),
  ));
  // Two routes deep, so a stray pop would visibly remove the second page.
  await tester.tap(find.text('push'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  return container;
}

void main() {
  testWidgets('opens SidebarContent in edit mode and closes on Done',
      (tester) async {
    final container = await _open(tester);
    expect(container.read(sidebarEditModeProvider), isTrue);
    expect(find.byType(SidebarEditBar), findsOneWidget);

    container.read(sidebarEditModeProvider.notifier).exit();
    await tester.pumpAndSettle();
    expect(find.byType(SidebarEditBar), findsNothing);
    expect(find.byKey(const Key('sidebar-edit-sheet')), findsNothing);
    // The underlying route survives the sheet closing.
    expect(find.text('second page'), findsOneWidget);
  });

  testWidgets('closing the sheet after its opener unmounted still exits',
      (tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(overrides: [
      sidebarLayoutStoreProvider
          .overrideWithValue(InMemorySidebarLayoutStore()),
      thirdPartySourcesProvider.overrideWithValue(const [fakeSource]),
      hasMydiaProvider.overrideWithValue(true),
      mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
    ]);
    addTearDown(container.dispose);
    final mounted = ValueNotifier(true);
    addTearDown(mounted.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ValueListenableBuilder<bool>(
          valueListenable: mounted,
          builder: (_, show, __) => show
              ? Consumer(
                  builder: (context, ref, _) => TextButton(
                    onPressed: () => showSidebarEditSheet(
                      context: context,
                      ref: ref,
                      location: '/s/acc1:owner:aa11',
                    ),
                    child: const Text('open'),
                  ),
                )
              : const SizedBox(),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sidebar-edit-sheet')), findsOneWidget);

    // The iPad going compact swaps the host out while the sheet is up.
    mounted.value = false;
    await tester.pump();
    expect(find.text('open'), findsNothing);
    container.read(sidebarEditModeProvider.notifier).exit();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(container.read(sidebarEditModeProvider), isFalse);
  });

  testWidgets('dismissing the sheet leaves edit mode', (tester) async {
    final container = await _open(tester);
    // The sheet covers 80% of the height, so the top strip is the barrier.
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('sidebar-edit-sheet')), findsNothing);
    expect(container.read(sidebarEditModeProvider), isFalse);
    expect(find.text('second page'), findsOneWidget);
  });
}
