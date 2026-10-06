import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/downloads/download_service.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/detail/detail_target.dart';
import 'package:player/domain/detail/detail_views.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/download_option.dart';
import 'package:player/domain/models/download_request.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/show/show_season_section.dart';
import 'package:player/presentation/widgets/quality_download_dialog.dart';

import '../../../test_utils/toast_harness.dart';
import '../sources/fake_capable_source.dart';
import '../sources/fake_media_source.dart';

ShowView _show({Set<DetailFeature> features = const {}}) => ShowView(
      target: SourceTarget(fakeShow.ref),
      title: 'Invented Series',
      seasons: [SeasonView(number: 1, target: SourceTarget(fakeSeason.ref))],
      features: features,
    );

/// A download manager that has downloaded nothing and records what starts.
class _RecordingService extends Fake implements DownloadService {
  final started = <DownloadRequest>[];

  @override
  List<DownloadTask> getActiveDownloads() => const [];

  @override
  bool isDownloaded(ItemRef ref) => false;

  @override
  Future<DownloadTask> start(DownloadRequest request) async {
    started.add(request);
    return DownloadTask(
      id: request.ref.externalId,
      mediaId: request.ref.externalId,
      title: request.metadata.title,
      quality: request.optionId,
      status: 'queued',
      createdAt: DateTime(2026),
    );
  }
}

Future<void> _pump(
  WidgetTester tester,
  ShowView show, {
  FakeMediaSource? source,
  _RecordingService? service,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      if (source != null)
        mediaSourceProvider(fakeSourceId).overrideWithValue(source),
      downloadManagerProvider
          .overrideWith((ref) async => service ?? _RecordingService()),
    ],
    child: MaterialApp(
      builder: toastLayerBuilder,
      home: Scaffold(body: ShowSeasonSection(show: show)),
    ),
  ));
  await tester.pumpAndSettle();
}

const _options = [
  DownloadOption(resolution: '1080p', label: '1080p', estimatedSize: 2),
  DownloadOption(resolution: '720p', label: '720p', estimatedSize: 1),
];

void main() {
  testWidgets('a source show with season download gets the season button',
      (tester) async {
    await _pump(tester, _show(features: {DetailFeature.seasonDownload}));
    expect(find.byKey(const Key('source-season-download')), findsOneWidget);
  });

  testWidgets('without the feature there is no download button',
      (tester) async {
    await _pump(tester, _show());
    expect(find.byKey(const Key('source-season-download')), findsNothing);
  });

  testWidgets('more than one option asks for a quality, and it is queued',
      (tester) async {
    final service = _RecordingService();
    await _pump(
      tester,
      _show(features: {DetailFeature.seasonDownload}),
      source: FakeCapableSource()..downloadOptionsResult = _options,
      service: service,
    );

    await tester.tap(find.byKey(const Key('source-season-download')));
    await tester.pumpAndSettle();
    expect(find.byType(QualityDownloadDialog), findsOneWidget);

    await tester.tap(find.byKey(const Key('download-option-720p')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Download'));
    await tester.pumpAndSettle();

    expect(service.started.map((r) => r.ref.externalId), ['e1', 'e2']);
    expect(service.started.map((r) => r.optionId), ['720p', '720p']);
  });

  testWidgets('cancelling the quality dialog queues nothing', (tester) async {
    final service = _RecordingService();
    await _pump(
      tester,
      _show(features: {DetailFeature.seasonDownload}),
      source: FakeCapableSource()..downloadOptionsResult = _options,
      service: service,
    );

    await tester.tap(find.byKey(const Key('source-season-download')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(service.started, isEmpty);
  });

  testWidgets('a lone option is queued without asking', (tester) async {
    final service = _RecordingService();
    await _pump(
      tester,
      _show(features: {DetailFeature.seasonDownload}),
      source: FakeCapableSource()
        ..downloadOptionsResult = const [
          DownloadOption(
              resolution: 'original', label: 'Original', estimatedSize: 1),
        ],
      service: service,
    );

    await tester.tap(find.byKey(const Key('source-season-download')));
    await tester.pumpAndSettle();

    expect(find.byType(QualityDownloadDialog), findsNothing);
    expect(service.started.map((r) => r.optionId), ['original', 'original']);
  });
}
