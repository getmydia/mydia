import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:player/core/downloads/orphan_download_sweep.dart';
import 'package:player/core/playback/playback_progress_providers.dart';
import 'package:player/core/sources/media_source.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/presentation/widgets/app_shell.dart';
import 'package:player/presentation/widgets/offline_banner.dart';

import '../../test_utils/mydia_test_source.dart';
import '../../test_utils/toast_harness.dart';
import '../screens/sources/fake_media_source.dart';

class _Src extends FakeMediaSource {
  _Src(this._source);
  final Source _source;

  @override
  Source get source => _source;
}

const _plexId = fakeSourceId;

/// Pumps the real shell at [location], with a Mydia and a Plex source
/// whose statuses the caller sets, and Plex as the active source.
Future<void> _pumpShell(
  WidgetTester tester,
  String location, {
  required SourceConnectionStatus mydia,
  required SourceConnectionStatus plex,
}) async {
  tester.view.physicalSize = const Size(1400, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final mydiaSource = _Src(testMydiaSource)..setStatus(mydia);
  final plexSource = _Src(fakeSource)..setStatus(plex);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      sourceProgressFlushProvider.overrideWith((ref) {}),
      orphanDownloadSweepProvider.overrideWith((ref) {}),
      activeSourceIdProvider.overrideWithValue(_plexId),
      mediaSourceProvider(testMydiaSourceId).overrideWithValue(mydiaSource),
      mediaSourceProvider(_plexId).overrideWithValue(plexSource),
    ],
    child: MaterialApp.router(
      builder: toastLayerBuilder,
      routerConfig: GoRouter(routes: [
        GoRoute(
          path: '/',
          builder: (_, __) =>
              AppShell(location: location, child: const SizedBox.expand()),
        ),
      ]),
    ),
  ));
  await tester.pump();
}

void main() {
  test('offline mode still reaches downloads and third-party sources', () {
    expect(offlineRouteAllowed('/downloads'), isTrue);
    expect(offlineRouteAllowed('/s/acc1:owner:aa11'), isTrue);
    expect(offlineRouteAllowed('/s/acc1:owner:aa11/library/movies'), isTrue);
    expect(offlineRouteAllowed('/sources/manage'), isTrue);
  });

  test('offline mode still blocks Mydia library routes', () {
    expect(offlineRouteAllowed('/movies'), isFalse);
    expect(offlineRouteAllowed('/'), isFalse);
    expect(offlineRouteAllowed('/settings'), isFalse);
  });

  group('the shell follows the source its route belongs to', () {
    testWidgets('Plex unreachable while on a Mydia route: no banner',
        (tester) async {
      await _pumpShell(tester, '/s/${testMydiaSourceId.value}',
          mydia: SourceConnectionStatus.remote,
          plex: SourceConnectionStatus.unreachable);
      expect(find.byType(OfflineBanner), findsNothing);
    });

    testWidgets('off any source route the active source decides',
        (tester) async {
      await _pumpShell(tester, '/sources/manage',
          mydia: SourceConnectionStatus.remote,
          plex: SourceConnectionStatus.unreachable);
      expect(find.byType(OfflineBanner), findsOneWidget);
    });

    testWidgets('on the Plex route with Plex unreachable: banner shows',
        (tester) async {
      await _pumpShell(tester, '/s/${_plexId.value}',
          mydia: SourceConnectionStatus.remote,
          plex: SourceConnectionStatus.unreachable);
      expect(find.byType(OfflineBanner), findsOneWidget);
    });

    testWidgets('Mydia unreachable on its own route: banner shows',
        (tester) async {
      await _pumpShell(tester, '/s/${testMydiaSourceId.value}',
          mydia: SourceConnectionStatus.unreachable,
          plex: SourceConnectionStatus.remote);
      expect(find.byType(OfflineBanner), findsOneWidget);
    });
  });
}
