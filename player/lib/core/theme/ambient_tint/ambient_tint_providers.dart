import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/painting.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../../presentation/widgets/ambient_backdrop_provider.dart';
import '../../cache/artwork_decode.dart';
import '../../cache/poster_cache_manager.dart';
import 'ambient_tint_colors.dart';
import 'tint_cache.dart';
import 'tint_extraction.dart';

part 'ambient_tint_providers.g.dart';

typedef TintExtractor = Future<Color?> Function(BackdropSource source);

/// How a source's artwork becomes a seed colour. Overridden in tests.
@Riverpod(keepAlive: true)
TintExtractor tintExtractor(Ref ref) => (source) {
      final url = source.imageUrl;
      if (url == null || url.isEmpty) return Future.value();
      return extractTint(
        artworkImageProvider(
          url,
          cacheManager: BackdropCacheManager(),
          decodeWidth: tintDecodeWidth,
          headers: source.headers.isEmpty ? null : source.headers,
          cacheKey: source.cacheKey,
        ),
      );
    };

@Riverpod(keepAlive: true)
TintCache tintCache(Ref ref) => TintCache();

/// The tint for one artwork, from the cache when it has been seen before.
/// Failures and grey art resolve to the neutral tint and are cached too, so
/// a broken image is not retried on every focus.
@riverpod
Future<AmbientTintColors> tintForSource(Ref ref, BackdropSource source) async {
  final url = source.imageUrl;
  if (url == null || url.isEmpty) return AmbientTintColors.neutral;
  final key = source.id ?? url;
  final cache = ref.read(tintCacheProvider);
  final hit = cache.get(key);
  if (hit != null) return hit;

  final extract = ref.read(tintExtractorProvider);
  Color? seed;
  try {
    seed = await extract(source);
  } catch (e) {
    debugPrint('[AmbientTint] $key: $e');
  }
  final colors = seed == null
      ? AmbientTintColors.neutral
      : AmbientTintColors.fromSeed(seed);
  cache.put(key, colors);
  return colors;
}

/// The shell's tint: follows the ambient backdrop, but only once it has
/// settled for [debounce], so holding a D-pad direction extracts nothing
/// until focus stops.
///
/// Path taken: primary. The controller holds a `ref.listen` subscription on
/// the autoDispose [tintForSourceProvider] family while it resolves.
@Riverpod(keepAlive: true)
class AmbientTintController extends _$AmbientTintController {
  static const Duration debounce = Duration(milliseconds: 150);

  Timer? _timer;
  int _generation = 0;

  @override
  AmbientTintColors build() {
    ref.onDispose(() => _timer?.cancel());
    ref.listen(
      ambientBackdropControllerProvider,
      (_, next) => _schedule(next),
      fireImmediately: true,
    );
    return AmbientTintColors.neutral;
  }

  void _schedule(BackdropSource source) {
    _timer?.cancel();
    final generation = ++_generation;
    _timer = Timer(debounce, () => _resolve(source, generation));
  }

  Future<void> _resolve(BackdropSource source, int generation) async {
    // A subscription, not ref.read: the family is autoDispose and a bare read
    // can dispose it before the future completes (player/docs/riverpod.md).
    final sub = ref.listen(tintForSourceProvider(source).future, (_, __) {});
    try {
      final colors = await sub.read();
      if (!ref.mounted || generation != _generation) return;
      state = colors;
    } finally {
      sub.close();
    }
  }
}
