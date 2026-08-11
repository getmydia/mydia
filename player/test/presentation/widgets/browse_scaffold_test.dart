import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/graphql/watch/freshness.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/presentation/widgets/browse_scaffold.dart';

/// Mirrors the stub in `freshness_header_test.dart`. The real
/// `AuthStateNotifier` reaches for secure storage on build, which a widget
/// test has no business doing.
class _StubAuthState extends AuthStateNotifier {
  @override
  AsyncValue<AuthStatus> build() =>
      const AsyncValue.data(AuthStatus.authenticated);
}

const _bodyKey = Key('browse-scaffold-test-body');

/// The scaffold on its own, for tests that need to control how it is routed
/// to rather than mounting it as `home`.
final _scaffoldUnderTest = BrowseScaffold(
  icon: Icons.search_rounded,
  title: 'Search',
  queryKeys: [QueryKeys.unwatched],
  body: (context, scrollTopPadding) => ListView(
    padding: EdgeInsets.only(top: scrollTopPadding),
    children: const [SizedBox(key: _bodyKey, height: 400, width: 400)],
  ),
);

Future<void> pumpScaffold(
  WidgetTester tester, {
  required Size size,
  Widget? secondRow,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authStateProvider.overrideWith(_StubAuthState.new),
        castCapabilitiesProvider
            .overrideWithValue(const CastCapabilities.full()),
      ],
      child: MaterialApp(
        home: BrowseScaffold(
          icon: Icons.visibility_off_rounded,
          title: 'Unwatched',
          queryKeys: [QueryKeys.unwatched],
          secondRow: secondRow,
          body: (context, scrollTopPadding) => ListView(
            padding: EdgeInsets.only(top: scrollTopPadding),
            children: const [
              SizedBox(key: _bodyKey, height: 400, width: 400),
            ],
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('renders the title on desktop, where the old bar was absent',
      (tester) async {
    await pumpScaffold(tester, size: const Size(1200, 900));

    expect(find.text('Unwatched'), findsOneWidget);
    expect(find.byIcon(Icons.visibility_off_rounded), findsOneWidget);
  });

  testWidgets('renders the title and a drawer button on mobile',
      (tester) async {
    await pumpScaffold(tester, size: const Size(400, 800));

    expect(find.text('Unwatched'), findsOneWidget);
    expect(find.byIcon(Icons.menu_rounded), findsOneWidget);
  });

  testWidgets('omits the drawer button on desktop', (tester) async {
    await pumpScaffold(tester, size: const Size(1200, 900));

    expect(find.byIcon(Icons.menu_rounded), findsNothing);
  });

  testWidgets('carries its own cast button', (tester) async {
    await pumpScaffold(tester, size: const Size(1200, 900));

    expect(find.byKey(const Key('cast-button')), findsOneWidget);
  });

  testWidgets('an in-flight refetch does not move the body', (tester) async {
    await pumpScaffold(tester, size: const Size(1200, 900));

    final before = tester.getTopLeft(find.byKey(_bodyKey));

    // Drive the real registry the way a live watcher does. This is the
    // regression: as a `Column` sibling the header was charged as layout
    // height and shoved the whole grid down on every background refetch.
    final container = ProviderScope.containerOf(
      tester.element(find.byType(BrowseScaffold)),
    );
    container.read(freshnessRegistryProvider.notifier).publish(
          QueryKeys.unwatched,
          const Freshness(isRefreshing: true, hasData: true),
        );
    await tester.pump();

    expect(tester.getTopLeft(find.byKey(_bodyKey)), before);
  });

  testWidgets('a second row makes the bar taller and insets the body',
      (tester) async {
    await pumpScaffold(tester, size: const Size(1200, 900));
    final withoutRow = tester.getTopLeft(find.byKey(_bodyKey)).dy;

    await pumpScaffold(
      tester,
      size: const Size(1200, 900),
      secondRow: const TextField(key: Key('second-row-field')),
    );
    final withRow = tester.getTopLeft(find.byKey(_bodyKey)).dy;

    expect(find.byKey(const Key('second-row-field')), findsOneWidget);
    expect(withRow - withoutRow, BrowseScaffold.secondRowHeight);
  });

  group('when the screen was pushed rather than navigated to', () {
    // Search is reached with `context.push('/search')` from every other
    // browse screen, which puts it on top of the shell navigator. Without a
    // back affordance that push is a one-way trip: the drawer hamburger goes
    // sideways, not back, and desktop had no leading control at all.
    Future<void> pumpPushed(WidgetTester tester, {required Size size}) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authStateProvider.overrideWith(_StubAuthState.new),
            castCapabilitiesProvider
                .overrideWithValue(const CastCapabilities.full()),
          ],
          child: MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  key: const Key('push-trigger'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => _scaffoldUnderTest,
                    ),
                  ),
                  child: const Text('push'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('push-trigger')));
      await tester.pumpAndSettle();
    }

    testWidgets('offers back instead of the drawer on mobile', (tester) async {
      await pumpPushed(tester, size: const Size(400, 800));

      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
      expect(find.byIcon(Icons.menu_rounded), findsNothing);
    });

    testWidgets(
        'offers back on desktop, which otherwise has no leading '
        'control at all', (tester) async {
      await pumpPushed(tester, size: const Size(1200, 900));

      expect(find.byIcon(Icons.arrow_back_rounded), findsOneWidget);
    });

    testWidgets('back actually pops the route', (tester) async {
      await pumpPushed(tester, size: const Size(400, 800));

      await tester.tap(find.byIcon(Icons.arrow_back_rounded));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('push-trigger')), findsOneWidget);
    });
  });
}
