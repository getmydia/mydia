import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/downloads/download_providers.dart';
import 'package:player/core/sources/sources_providers.dart';
import 'package:player/domain/models/download.dart';
import 'package:player/domain/models/download_request.dart';
import 'package:player/domain/sources/item.dart';
import 'package:player/presentation/screens/detail/start_download.dart';

import '../../../test_utils/toast_harness.dart';
import '../sources/fake_media_source.dart';
import 'download_fakes.dart';

const _movie =
    ItemRef(sourceId: fakeSourceId, kind: ItemKind.movie, externalId: 'm1');

Future<void> _pump(WidgetTester tester, FakeMediaSource? source) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [
      mediaSourceProvider(fakeSourceId).overrideWithValue(source),
      downloadManagerProvider
          .overrideWith((ref) async => EmptyDownloadService()),
    ],
    child: MaterialApp(
      builder: toastLayerBuilder,
      home: Consumer(
        builder: (context, ref, _) => TextButton(
          key: const Key('go'),
          onPressed: () => startItemDownload(
            context,
            ref,
            item: _movie,
            metadata: const DownloadMetadata(
                title: 'Quill Harbor', mediaType: MediaType.movie),
          ),
          child: const Text('go'),
        ),
      ),
    ),
  ));
}

void main() {
  const message = 'This server is not available to download from';

  testWidgets('a source that is gone says so instead of doing nothing',
      (tester) async {
    await _pump(tester, null);
    await tester.tap(find.byKey(const Key('go')));
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
  });

  testWidgets('a source that cannot download says so', (tester) async {
    await _pump(tester, FakeMediaSource());
    await tester.tap(find.byKey(const Key('go')));
    await tester.pumpAndSettle();
    expect(find.text(message), findsOneWidget);
  });
}
