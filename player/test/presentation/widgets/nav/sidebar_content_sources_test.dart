// Sidebar edit mode arranges Mydia's destinations, so third-party source
// locations offer neither the pencil nor the edit bar.

import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/connection/connection_provider.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/navigation/sidebar_layout_providers.dart';
import 'package:player/core/navigation/sidebar_layout_store.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/nav/sidebar_content.dart';
import 'package:player/presentation/widgets/nav/sidebar_edit_bar.dart';

import '../../screens/sources/fake_media_source.dart';

class _StubConnectionNotifier extends ConnectionNotifier {
  @override
  ConnectionState build() => ConnectionState.direct();
}

class _FixedAuth extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() => const AsyncData(AuthStatus.authenticated);
}

Future<void> _pump(WidgetTester tester, String location) async {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final container = ProviderContainer(overrides: [
    connectionProvider.overrideWith(_StubConnectionNotifier.new),
    authStateProvider.overrideWith(_FixedAuth.new),
    sidebarLayoutStoreProvider.overrideWithValue(InMemorySidebarLayoutStore()),
    thirdPartySourcesProvider.overrideWithValue(const [fakeSource]),
    mediaSourceProvider(fakeSourceId).overrideWithValue(FakeMediaSource()),
  ]);
  addTearDown(container.dispose);
  container.read(sidebarEditModeProvider.notifier).toggle();
  await tester.pumpWidget(UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 260,
          height: 1400,
          child: SidebarContent(
            location: location,
            onNavigate: (_) {},
            isOffline: false,
          ),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a source location shows no edit pencil and no edit bar',
      (tester) async {
    await _pump(tester, '/s/${fakeSourceId.value}');
    expect(find.byTooltip('Edit sidebar'), findsNothing);
    expect(find.byType(SidebarEditBar), findsNothing);
  });

  testWidgets('positive control: a Mydia location keeps both', (tester) async {
    await _pump(tester, '/');
    expect(find.byTooltip('Edit sidebar'), findsOneWidget);
    expect(find.byType(SidebarEditBar), findsOneWidget);
  });
}
