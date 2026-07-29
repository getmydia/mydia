import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// `Override` is not re-exported by the main `flutter_riverpod.dart` barrel in
// Riverpod 3.x; it lives in the `misc.dart` sub-library alongside other
// advanced/library-author types (see `test/test_utils/riverpod_helpers.dart`).
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/auth/auth_status.dart';
import 'package:player/core/graphql/graphql_provider.dart';
import 'package:player/core/graphql/watch/freshness.dart';
import 'package:player/core/graphql/watch/query_key.dart';
import 'package:player/core/graphql/watch/watcher_registry.dart';
import 'package:player/presentation/widgets/freshness_header.dart';

class _StubFreshnessRegistry extends FreshnessRegistry {
  _StubFreshnessRegistry(this._initial);

  final Map<QueryKey, Freshness> _initial;

  @override
  Map<QueryKey, Freshness> build() => _initial;
}

class _StubAuthState extends AuthStateNotifier {
  _StubAuthState(this._status);

  final AuthStatus _status;

  @override
  AsyncValue<AuthStatus> build() => AsyncValue.data(_status);
}

/// Records exactly which keys the widget asked to be invalidated, so tests
/// can tell a correct wiring from a hardcoded or mismatched one.
class _RecordingInvalidator implements Invalidator {
  final List<QueryKey> invalidatedKeys = [];

  @override
  Future<void> invalidate(Iterable<QueryKey> keys) async {
    invalidatedKeys.addAll(keys);
  }

  @override
  Future<void> invalidateAll() async {}
}

Future<void> pumpHeader(
  WidgetTester tester, {
  required Map<QueryKey, Freshness> freshness,
  AuthStatus authStatus = AuthStatus.authenticated,
  // Nullable rather than `= const [QueryKeys.home]`: `QueryKey` is no longer
  // const-constructible (see `query_key.dart`), so a `QueryKeys.home`
  // reference cannot appear in a default parameter value, which Dart
  // requires to be a compile-time constant.
  List<QueryKey>? keys,
  List<Override> extraOverrides = const [],
}) {
  return tester.pumpWidget(
    ProviderScope(
      overrides: [
        freshnessRegistryProvider
            .overrideWith(() => _StubFreshnessRegistry(freshness)),
        authStateProvider.overrideWith(() => _StubAuthState(authStatus)),
        ...extraOverrides,
      ],
      child: MaterialApp(
        home: Scaffold(
          body: FreshnessHeader(queryKeys: keys ?? [QueryKeys.home]),
        ),
      ),
    ),
  );
}

void main() {
  final now = DateTime.now();

  testWidgets('shows nothing when the data is fresh and idle', (tester) async {
    await pumpHeader(tester, freshness: {
      QueryKeys.home: Freshness(fetchedAt: now, isStale: false),
    });

    expect(find.byKey(const Key('freshness-inflight')), findsNothing);
    expect(find.byKey(const Key('freshness-banner')), findsNothing);
  });

  testWidgets('shows the in-flight line while refreshing', (tester) async {
    await pumpHeader(tester, freshness: {
      QueryKeys.home: Freshness(fetchedAt: now, isRefreshing: true),
    });

    expect(find.byKey(const Key('freshness-inflight')), findsOneWidget);
    expect(find.byKey(const Key('freshness-banner')), findsNothing);
  });

  testWidgets('suppresses the stale banner while a refresh is already running',
      (tester) async {
    // Tier 1 already covers a running refresh; showing both at once for the
    // same underlying condition is exactly what tier 2 exists to avoid.
    await pumpHeader(tester, freshness: {
      QueryKeys.home: Freshness(
        fetchedAt: now.subtract(const Duration(hours: 2)),
        isStale: true,
        isRefreshing: true,
      ),
    });

    expect(find.byKey(const Key('freshness-inflight')), findsOneWidget);
    expect(find.byKey(const Key('freshness-banner')), findsNothing);
  });

  testWidgets('shows the failure banner with a retry action', (tester) async {
    await pumpHeader(tester, freshness: {
      QueryKeys.home: Freshness(
        fetchedAt: now.subtract(const Duration(hours: 2)),
        refreshFailed: true,
        isStale: true,
        hasData: true,
      ),
    });

    expect(find.byKey(const Key('freshness-banner')), findsOneWidget);
    expect(
      find.text("Couldn't reach your server. Showing your library from "
          '2 hours ago.'),
      findsOneWidget,
    );
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('shows the stale banner with a refresh action', (tester) async {
    await pumpHeader(tester, freshness: {
      QueryKeys.home: Freshness(
        fetchedAt: now.subtract(const Duration(hours: 3)),
        isStale: true,
        hasData: true,
      ),
    });

    expect(
      find.text('Showing your library from 3 hours ago.'),
      findsOneWidget,
    );
    expect(find.text('Refresh'), findsOneWidget);
  });

  testWidgets('shows no banner when there is no timestamp to describe',
      (tester) async {
    // Cold start: stale by definition, but there is nothing on screen yet.
    await pumpHeader(tester, freshness: {
      QueryKeys.home: const Freshness(isStale: true),
    });

    expect(find.byKey(const Key('freshness-banner')), findsNothing);
  });

  testWidgets(
      'shows no banner for a stale key with a real fetchedAt but nothing on '
      'screen (a cold fetch still in flight)', (tester) async {
    // This is the case a bare `fetchedAt != null` gate got wrong: the age
    // gate picked `networkOnly` for a 20-minute-old log entry, so the first
    // result is `QueryResult.loading` with `data == null`. `fetchedAt` is
    // real (from the log) and `isStale` is true, but there is nothing on
    // screen yet, so the banner must not claim there is.
    await pumpHeader(tester, freshness: {
      QueryKeys.home: Freshness(
        fetchedAt: now.subtract(const Duration(minutes: 20)),
        isStale: true,
        hasData: false,
      ),
    });

    expect(find.byKey(const Key('freshness-banner')), findsNothing);
  });

  testWidgets(
      'shows the stale banner for the same fetchedAt once data is on screen',
      (tester) async {
    await pumpHeader(tester, freshness: {
      QueryKeys.home: Freshness(
        fetchedAt: now.subtract(const Duration(minutes: 20)),
        isStale: true,
        hasData: true,
      ),
    });

    expect(find.byKey(const Key('freshness-banner')), findsOneWidget);
  });

  testWidgets('renders nothing in offline mode', (tester) async {
    // OfflineBanner is already showing and explains the situation better.
    await pumpHeader(
      tester,
      authStatus: AuthStatus.offlineMode,
      freshness: {
        QueryKeys.home: Freshness(
          fetchedAt: now.subtract(const Duration(days: 1)),
          refreshFailed: true,
          isStale: true,
        ),
      },
    );

    expect(find.byKey(const Key('freshness-banner')), findsNothing);
    expect(find.byKey(const Key('freshness-inflight')), findsNothing);
  });

  testWidgets('combines the state of several keys on one screen',
      (tester) async {
    await pumpHeader(
      tester,
      keys: [QueryKeys.home, QueryKeys.unwatched],
      freshness: {
        QueryKeys.home: Freshness(fetchedAt: now),
        QueryKeys.unwatched: Freshness(fetchedAt: now, isRefreshing: true),
      },
    );

    expect(find.byKey(const Key('freshness-inflight')), findsOneWidget);
  });

  testWidgets("tapping the action invalidates exactly this header's query keys",
      (tester) async {
    final recorder = _RecordingInvalidator();
    final keys = [QueryKeys.home, QueryKeys.unwatched];

    await pumpHeader(
      tester,
      keys: keys,
      freshness: {
        QueryKeys.home: Freshness(
          fetchedAt: now.subtract(const Duration(hours: 2)),
          refreshFailed: true,
          isStale: true,
          hasData: true,
        ),
        QueryKeys.unwatched: Freshness(
          fetchedAt: now.subtract(const Duration(hours: 2)),
          refreshFailed: true,
          isStale: true,
          hasData: true,
        ),
      },
      extraOverrides: [
        invalidatorProvider.overrideWithValue(recorder),
      ],
    );

    await tester.tap(find.byKey(const Key('freshness-action')));
    await tester.pump();

    expect(recorder.invalidatedKeys, equals(keys));
  });
}
