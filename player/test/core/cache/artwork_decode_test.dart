import 'dart:io';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:cached_network_image_platform_interface/cached_network_image_platform_interface.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:player/core/cache/artwork_decode.dart';
import 'package:player/core/cache/poster_cache_manager.dart';

void main() {
  // PosterCacheManager/BackdropCacheManager are real flutter_cache_manager
  // singletons: constructing one hits path_provider for a temp and an app
  // support directory. Under plain test() (unlike testWidgets), an unmocked
  // platform channel throws MissingPluginException instead of hanging, so
  // this must run before either singleton is first built below.
  setUpAll(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (call) async => Directory.systemTemp.path,
    );
  });

  group('artworkDecodeWidth', () {
    test('rounds physical width up to a 64px bucket', () {
      expect(artworkDecodeWidth(140, 1), 192);
      expect(artworkDecodeWidth(128, 1), 128);
      expect(artworkDecodeWidth(129, 1), 192);
    });

    test('multiplies by device pixel ratio before bucketing', () {
      expect(artworkDecodeWidth(140, 2), 320);
      expect(artworkDecodeWidth(140, 3), 448);
    });

    test('caps at the source width', () {
      expect(artworkDecodeWidth(300, 2, sourceWidth: posterSourceWidth), 500);
      expect(
        artworkDecodeWidth(1920, 2, sourceWidth: backdropSourceWidth),
        1280,
      );
    });

    test('returns null for widths that cannot be sized', () {
      expect(artworkDecodeWidth(0, 2), isNull);
      expect(artworkDecodeWidth(-5, 2), isNull);
      expect(artworkDecodeWidth(double.infinity, 2), isNull);
      expect(artworkDecodeWidth(double.nan, 2), isNull);
      expect(artworkDecodeWidth(100, 0), isNull);
    });
  });

  group('artworkImageProvider', () {
    const url = 'https://image.tmdb.org/t/p/w500/a.jpg';

    test('wraps in ResizeImage when a decode width is given', () {
      final provider = artworkImageProvider(
        url,
        cacheManager: PosterCacheManager(),
        decodeWidth: 320,
      );

      expect(provider, isA<ResizeImage>());
      final resize = provider as ResizeImage;
      expect(resize.width, 320);
      expect(resize.height, isNull);
      final inner = resize.imageProvider as CachedNetworkImageProvider;
      expect(inner.url, url);
      expect(inner.imageRenderMethodForWeb, ImageRenderMethodForWeb.HttpGet);
    });

    test('returns the bare provider when there is no decode width', () {
      final provider =
          artworkImageProvider(url, cacheManager: PosterCacheManager());

      expect(provider, isA<CachedNetworkImageProvider>());
    });

    test('equal inputs give equal providers, so precache hits the same key',
        () {
      ImageProvider<Object> build() => artworkImageProvider(
            url,
            cacheManager: BackdropCacheManager(),
            decodeWidth: 1280,
          );

      expect(build(), equals(build()));
    });
  });

  testWidgets('viewportDecodeWidth reads MediaQuery size and ratio',
      (tester) async {
    int? width;
    await tester.pumpWidget(
      MediaQuery(
        data: const MediaQueryData(size: Size(400, 800), devicePixelRatio: 2),
        child: Builder(
          builder: (context) {
            width = viewportDecodeWidth(
              context,
              sourceWidth: backdropSourceWidth,
            );
            return const SizedBox();
          },
        ),
      ),
    );

    expect(width, 832);
  });
}
