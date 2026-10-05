import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/poster_cache_manager.dart';
import 'package:player/presentation/screens/downloads/widgets/download_artwork.dart';
import 'package:player/presentation/widgets/artwork_image.dart';

void main() {
  testWidgets('prefers the saved file', (tester) async {
    final dir = Directory.systemTemp.createTempSync('art_');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/p.jpg')..writeAsBytesSync([0]);
    await tester.pumpWidget(MaterialApp(
      home: DownloadArtwork(
          localPath: file.path,
          fallbackUrl: 'https://x.invalid/p',
          cacheManager: PosterCacheManager()),
    ));
    expect(find.byType(Image), findsOneWidget);
    expect(find.byType(ArtworkImage), findsNothing);
  });

  testWidgets('falls back to an http URL, never to a server path',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: DownloadArtwork(
          localPath: null,
          fallbackUrl: 'https://x.invalid/p',
          cacheManager: PosterCacheManager()),
    ));
    expect(find.byType(ArtworkImage), findsOneWidget);

    await tester.pumpWidget(MaterialApp(
      home: DownloadArtwork(
          localPath: null,
          fallbackUrl: '/library/metadata/1/thumb',
          cacheManager: PosterCacheManager()),
    ));
    expect(find.byType(ArtworkImage), findsNothing);
  });
}
