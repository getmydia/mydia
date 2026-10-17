import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/ambient_tint/ambient_tint.dart';
import '../../../core/theme/ambient_tint/ambient_tint_colors.dart';
import '../../../core/theme/ambient_tint/ambient_tint_providers.dart';
import '../../../core/theme/palette.dart';
import '../../../domain/detail/detail_art.dart';
import '../../widgets/ambient_backdrop_provider.dart';
import '../../widgets/source_artwork.dart';

/// Gives a detail screen the tint of its own artwork. Detail routes render
/// inside the shell, but the shell's tint follows whatever card was last
/// focused, so the screen resolves its own. Arriving from a focused
/// card is normally a cache hit, so the colour carries across.
class DetailTintScope extends ConsumerWidget {
  const DetailTintScope({super.key, required this.art, required this.child});

  final DetailArt? art;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final palette = context.palette;
    if (!palette.ambientTint) {
      return AmbientTintScope(
        colors: AmbientTintColors.neutralFor(palette),
        child: child,
      );
    }
    final source = _sourceFor(ref, art);
    final resolved =
        source == null ? null : ref.watch(tintForSourceProvider(source));
    return AmbientTintScope(
      // Until this screen's own tint resolves, carry the one already showing.
      colors: resolved != null && resolved.hasValue
          ? resolveAmbientTint(resolved.value, palette)
          : AmbientTint.of(context),
      child: child,
    );
  }

  static BackdropSource? _sourceFor(WidgetRef ref, DetailArt? art) =>
      switch (art) {
        null => null,
        UrlArt(:final url) => BackdropSource(imageUrl: url, id: url),
        SourceArt(:final sourceId, ref: final artRef) => switch (ref
              .watch(sourceArtworkProvider((
                sourceId: sourceId,
                art: artRef,
                width: SourceBackdrop.artworkWidth,
              )))
              .value) {
            final request? => BackdropSource(
                imageUrl: request.url,
                id: request.cacheKey,
                headers: request.headers,
                cacheKey: request.cacheKey,
              ),
            null => null,
          },
      };
}
