// When downloads come from more than one server, each card names its server;
// with a single server the screen stays as it was.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cast/cast_capabilities.dart';
import 'package:player/core/cast/cast_providers.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/storage_quota_providers.dart';
import 'package:player/core/sources/source.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/presentation/screens/downloads/downloads_screen.dart';

import '../../../test_utils/mock_network_images.dart';

Source _source(String account, String name) => Source(
      account: ProviderAccount(
        id: account,
        kind: SourceKind.mydia,
        displayName: name,
        storageNamespace: 'source/$account',
        activeProfileId: 'owner',
      ),
      profile: SourceProfile(
          id: 'owner', accountId: account, name: 'Owner', isOwner: true),
      server: SourceServer(
          id: 'inst', accountId: account, profileId: 'owner', name: name),
    );

final _a = _source('acca', 'Instance A');
final _b = _source('accb', 'Instance B');

DownloadedMedia _movie(String id, Source source) => DownloadedMedia(
      id: 'd-$id',
      mediaId: id,
      sourceId: source.id.value,
      title: 'Quill Harbor $id',
      quality: 'original',
      filePath: '/tmp/$id.mp4',
      fileSize: 1024,
      mediaType: 'movie',
      downloadedAt: DateTime(2026, 1, 1),
    );

Future<void> _pump(
  WidgetTester tester, {
  required List<DownloadedMedia> downloaded,
  required List<Source> sources,
}) async {
  await tester.binding.setSurfaceSize(const Size(900, 1600));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await mockNetworkImages(() async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          downloadedMediaProvider
              .overrideWith((ref) => Stream.value(downloaded)),
          downloadQueueProvider
              .overrideWith((ref) => Stream.value(<DownloadTask>[])),
          failedDownloadsProvider
              .overrideWith((ref) => Stream.value(<DownloadTask>[])),
          downloadSpeedInfoProvider.overrideWith((ref) => Stream.value({})),
          storageQuotaStatusProvider
              .overrideWith((ref) => Completer<StorageQuotaStatus>().future),
          sourcesProvider.overrideWithValue(sources),
          castCapabilitiesProvider
              .overrideWithValue(const CastCapabilities.full()),
        ],
        child: const MaterialApp(home: DownloadsScreen()),
      ),
    );
    await tester.pump();
    await tester.pump();
  });
}

void main() {
  testWidgets('names each card\'s server when two servers have downloads',
      (tester) async {
    await _pump(
      tester,
      downloaded: [_movie('10', _a), _movie('10', _b)],
      sources: [_a, _b],
    );

    expect(find.text('Instance A'), findsOneWidget);
    expect(find.text('Instance B'), findsOneWidget);
    expect(find.byKey(Key('download-group-source-${_a.id.value}')),
        findsOneWidget);
  });

  testWidgets('shows no server label when only one server has downloads',
      (tester) async {
    await _pump(
      tester,
      downloaded: [_movie('10', _a), _movie('11', _a)],
      sources: [_a, _b],
    );

    expect(find.text('Quill Harbor 10'), findsOneWidget);
    expect(find.text('Instance A'), findsNothing);
    expect(find.text('Instance B'), findsNothing);
  });

  testWidgets('a download from a removed server says so', (tester) async {
    await _pump(
      tester,
      downloaded: [_movie('10', _a), _movie('10', _b)],
      sources: [_a],
    );

    expect(find.text('Instance A'), findsOneWidget);
    expect(find.text('Removed server'), findsOneWidget);
  });
}
