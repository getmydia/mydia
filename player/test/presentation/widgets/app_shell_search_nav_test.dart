import 'package:flutter/material.dart' hide ConnectionState;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/connection/connection_provider.dart';
import 'package:player/presentation/widgets/app_shell.dart';

/// Keeps [ConnectionNotifier]'s async storage load out of the widget test; the
/// settings item's status badge is the only provider-touching child of the
/// sidebar content.
class _StubConnectionNotifier extends ConnectionNotifier {
  @override
  ConnectionState build() => ConnectionState.direct();
}

/// Enlarges the test viewport before mounting the sidebar content.
///
/// The default `flutter test` surface is 800x600 logical pixels, which caps
/// [Scaffold.body] well below the sidebar's fixed 900px test height (and the
/// sidebar's own content, expanded, needs more than the default 600px to lay
/// out without a spurious overflow). Without this, the requested SizedBox
/// height above is silently clamped and the sidebar overflows vertically
/// regardless of its actual content — a `flutter test` viewport artifact,
/// not a real layout bug (the deployed web player never faces this default).
Widget _host({
  required WidgetTester tester,
  required String location,
  required void Function(String) onNavigate,
}) {
  tester.view.physicalSize = const Size(1200, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  return ProviderScope(
    overrides: [
      connectionProvider.overrideWith(_StubConnectionNotifier.new),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 260,
          height: 900,
          child: SidebarContent(
            location: location,
            onNavigate: onNavigate,
            homeExpanded: true,
            libraryExpanded: true,
            onToggleHome: () {},
            onToggleLibrary: () {},
            isOffline: false,
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('the sidebar content exposes a Search destination',
      (tester) async {
    await tester
        .pumpWidget(_host(tester: tester, location: '/', onNavigate: (_) {}));

    expect(find.text('Search'), findsOneWidget);
  });

  testWidgets('tapping Search navigates to /search', (tester) async {
    final routes = <String>[];

    await tester.pumpWidget(
        _host(tester: tester, location: '/', onNavigate: routes.add));
    await tester.tap(find.text('Search'));
    await tester.pump();

    expect(routes, ['/search']);
  });

  testWidgets('Search is highlighted when the location is /search',
      (tester) async {
    await tester.pumpWidget(
        _host(tester: tester, location: '/search', onNavigate: (_) {}));

    final label = tester.widget<Text>(find.text('Search'));
    expect(label.style?.fontWeight, FontWeight.w600);
  });
}
