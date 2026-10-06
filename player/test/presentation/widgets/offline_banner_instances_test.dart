import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/cache/fetch_log.dart';
import 'package:player/core/sources/cache/source_cache.dart';
import 'package:player/core/sources/cache/source_codecs.dart';
import 'package:player/core/sources/cache/source_keys.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/sources/source_error.dart';
import 'package:player/presentation/screens/sources/source_error_view.dart';
import 'package:player/presentation/screens/sources/source_home_screen.dart';
import 'package:player/presentation/widgets/app_shell.dart';
import 'package:player/presentation/widgets/offline_banner.dart';
import 'package:player/presentation/widgets/source_artwork.dart';

import '../../test_utils/toast_harness.dart';
import '../screens/sources/fake_media_source.dart';

// The shell case below is skipped: 'Needs phase 1B Task 8
// (currentSourceStatusProvider)'. Today the banner follows the global auth
// state, so it cannot tell instance A from instance B.

const _idA = SourceId('acc1:owner:aa11');
const _idB = SourceId('acc2:owner:bb22');

/// A source whose connection status the test drives.
class _StatusSource extends FakeResumingSource {
  _StatusSource(SourceConnectionStatus status, {super.resuming})
      : _notifier = ValueNotifier(status);

  final ValueNotifier<SourceConnectionStatus> _notifier;

  @override
  SourceConnectionStatus get connection => _notifier.value;

  @override
  ValueListenable<SourceConnectionStatus> get statusListenable => _notifier;
}

Future<void> _pumpShell(
  WidgetTester tester,
  String initial, {
  required _StatusSource a,
  required _StatusSource b,
}) async {
  final router = GoRouter(
    initialLocation: initial,
    routes: [
      ShellRoute(
        builder: (_, state, child) =>
            AppShell(location: state.uri.path, child: child),
        routes: [
          GoRoute(
            path: '/s/:id/',
            builder: (_, state) => const SizedBox(),
          ),
        ],
      ),
    ],
  );
  await tester.binding.setSurfaceSize(const Size(1280, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mediaSourceProvider(_idA).overrideWithValue(a),
      mediaSourceProvider(_idB).overrideWithValue(b),
    ],
    child: MaterialApp.router(routerConfig: router),
  ));
  await tester.pump();
}

void main() {
  testWidgets('the banner follows the source on screen, not the others',
      (tester) async {
    final a = _StatusSource(SourceConnectionStatus.unreachable);
    final b = _StatusSource(SourceConnectionStatus.remote);
    await _pumpShell(tester, '/s/${_idA.value}/', a: a, b: b);
    expect(find.byType(OfflineBanner), findsOneWidget);

    final context = tester.element(find.byType(AppShell));
    GoRouter.of(context).go('/s/${_idB.value}/');
    await tester.pump();
    expect(find.byType(OfflineBanner), findsNothing);
  }, skip: true); // _skipUntilTask8

  testWidgets('an unreachable source shows its stored rows, not an error',
      (tester) async {
    final stored = [fakeMovie(1), fakeMovie(2)];
    final key = SourceKeys.continueWatching(fakeSourceId);
    final cache = InMemorySourceCache();
    final now = DateTime.now();
    await cache.write(key, encodeSummaries(stored), now);
    final fetchLog = InMemoryFetchLog({key: now});

    final source = _StatusSource(
      SourceConnectionStatus.unreachable,
      resuming: stored,
    )..continueError = const SourceException.unreachable();

    final router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (_, __) => const SourceHomeScreen(sourceId: fakeSourceId),
      ),
    ]);
    await tester.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        mediaSourceProvider(fakeSourceId).overrideWithValue(source),
        sourceCacheProvider.overrideWithValue(cache),
        fetchLogProvider.overrideWithValue(fetchLog),
        sourceArtworkProvider.overrideWith((ref, key) async => null),
      ],
      child:
          MaterialApp.router(routerConfig: router, builder: toastLayerBuilder),
    ));
    await tester.pumpAndSettle();

    // The libraries row lists the same fake films, so look inside the row
    // that only the stored answer can fill.
    final row = find.byKey(const Key('source-continue-watching'));
    expect(row, findsOneWidget);
    for (final title in ['Invented Film 1', 'Invented Film 2']) {
      expect(
          find.descendant(of: row, matching: find.text(title)), findsOneWidget);
    }
    expect(find.byType(SourceErrorView), findsNothing);
  });
}
