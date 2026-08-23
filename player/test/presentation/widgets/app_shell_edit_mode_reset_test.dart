import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/presentation/widgets/app_shell.dart';

/// Pumps a bare `Consumer` and hands back its ref.
///
/// [AppShell.onDrawerVisibilityChanged] takes a `WidgetRef`, and mounting the
/// whole shell to obtain one would drag in auth, GraphQL, connection and
/// compatibility stubs for the sake of a two-line handler.
Future<WidgetRef> _pumpRef(
  WidgetTester tester,
  ProviderContainer container,
) async {
  late WidgetRef captured;
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) {
            captured = ref;
            return const SizedBox();
          },
        ),
      ),
    ),
  );
  return captured;
}

void main() {
  ProviderContainer makeContainer() {
    final container = ProviderContainer(
      overrides: [
        sidebarLayoutStoreProvider
            .overrideWithValue(InMemorySidebarLayoutStore()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  testWidgets('a closing drawer exits edit mode', (tester) async {
    final container = makeContainer();
    final ref = await _pumpRef(tester, container);

    container.read(sidebarEditModeProvider.notifier).toggle();
    expect(container.read(sidebarEditModeProvider), isTrue);

    AppShell.onDrawerVisibilityChanged(isOpen: false, ref: ref);
    await tester.pump();

    expect(container.read(sidebarEditModeProvider), isFalse);
  });

  testWidgets('an opening drawer leaves edit mode alone', (tester) async {
    final container = makeContainer();
    final ref = await _pumpRef(tester, container);

    container.read(sidebarEditModeProvider.notifier).toggle();

    AppShell.onDrawerVisibilityChanged(isOpen: true, ref: ref);
    await tester.pump();

    expect(container.read(sidebarEditModeProvider), isTrue);
  });
}
