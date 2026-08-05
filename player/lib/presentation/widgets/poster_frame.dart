import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/cache/poster_cache_manager.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/depth_tokens.dart';
import '../../core/ui/reduced_motion.dart';
import 'ambient_backdrop_provider.dart';

/// The single owner of the player's poster depth contract (R7, R8, R11) and
/// of loading the artwork that sits inside it.
///
/// Every poster-shaped surface composes this rather than hand-rolling the
/// treatment: the library grid and list (`MediaPoster`), the home rails
/// (`MediaCard`), and search results (`SearchResultCard`). The contract was
/// hand-rolled three times before this widget existed and had already drifted
/// once, which is what this centralization prevents.
///
/// What it owns:
///
///  * a [ClipRRect] at [DepthTokens.radiusPoster];
///  * an always-on resting shadow that firms up slightly on hover (R7), never a
///    lift and never a scale (R11). There is deliberately no [Transform] in
///    this subtree, so the no-scale rule is structural rather than a convention
///    each caller has to remember;
///  * reduced-motion collapse, where the hover accent disappears and the
///    resting shadow stays;
///  * loading the artwork itself, via [CachedNetworkImage]. This is bundled
///    with the depth contract deliberately, not incidentally: if network image
///    loading were reachable without going through this widget, a fresh author
///    wiring up their own `CachedNetworkImage` would have no reason to ever
///    reach for the depth tokens, and the contract would drift a fourth time;
///  * publishing the hovered artwork to the ambient backdrop (R5/R9).
///
/// What it does not own: sizing (it fills its constraints and the caller sizes
/// it), tap handling (tap targets differ per caller, some including the title
/// label), and the appearance of any overlay.
///
/// Composing this widget is necessary but not sufficient to inherit the
/// contract. The "no lift, no scale" guarantee holds only *inside* this
/// widget's own subtree — a caller that wraps it in its own [Transform] (a
/// bare [AnimatedScale], say) reintroduces exactly the motion this widget
/// exists to forbid, and nothing in here can see that from outside.
/// `SearchResultCard` did exactly this during this widget's rollout. The only
/// trip-wire is the shared test suite: any surface composing [PosterFrame]
/// must run `runPosterDepthContract` against itself, the way
/// `poster_frame_test.dart`, `media_poster_test.dart`, `media_card_test.dart`,
/// and `search_widgets_test.dart` already do.
class PosterFrame extends ConsumerStatefulWidget {
  /// Artwork URL. Null, empty, or a load failure renders [placeholder].
  final String? imageUrl;

  /// Rendered when there is no artwork, and on load failure. Callers supply
  /// their own icon and ground so each surface stays recognisable.
  final Widget placeholder;

  /// Rendered while artwork loads. Falls back to [placeholder] when omitted.
  final Widget? loadingPlaceholder;

  /// Painted above the artwork at all times, in order. Every entry must
  /// position itself, either directly as a [Positioned] or through a widget
  /// that renders one (`ProgressOverlay`, for example), since the stack
  /// expands any non-positioned child.
  final List<Widget> overlays;

  /// Cross-faded in while hovered. Each surface keeps its own treatment.
  final Widget? hoverOverlay;

  const PosterFrame({
    super.key,
    this.imageUrl,
    required this.placeholder,
    this.loadingPlaceholder,
    this.overlays = const <Widget>[],
    this.hoverOverlay,
  });

  @override
  ConsumerState<PosterFrame> createState() => _PosterFrameState();
}

class _PosterFrameState extends ConsumerState<PosterFrame> {
  bool _isHovered = false;

  bool get _hasArtwork {
    final url = widget.imageUrl;
    return url != null && url.isNotEmpty;
  }

  void _handleHoverEnter() {
    setState(() => _isHovered = true);
    // Drive the ambient backdrop to this poster's artwork so the real-blur
    // chrome tints with it (R5/R9). Skipped when there is no artwork.
    if (_hasArtwork) {
      publishBackdropHover(
        ref,
        BackdropSource(imageUrl: widget.imageUrl, id: widget.imageUrl),
      );
    }
  }

  void _handleHoverExit() {
    setState(() => _isHovered = false);
    clearBackdropHover(ref);
  }

  @override
  Widget build(BuildContext context) {
    // Unconditional: `radiusPoster` is the one radius every poster surface
    // now shares, and a caller-supplied override would just reopen the exact
    // radius drift this widget exists to close.
    final radius = BorderRadius.circular(DepthTokens.radiusPoster);
    final reduceMotion = context.reduceMotion;
    final deepened = _isHovered && !reduceMotion;
    final motion = reduceMotion ? Duration.zero : DepthTokens.motionMedium;
    final url = widget.imageUrl;

    return MouseRegion(
      onEnter: (_) => _handleHoverEnter(),
      onExit: (_) => _handleHoverExit(),
      child: AnimatedContainer(
        duration: motion,
        curve: DepthTokens.curveStandard,
        decoration: BoxDecoration(
          borderRadius: radius,
          boxShadow:
              deepened ? DepthTokens.posterHover : DepthTokens.posterResting,
        ),
        child: ClipRRect(
          borderRadius: radius,
          child: Stack(
            fit: StackFit.expand,
            children: [
              if (url != null && url.isNotEmpty)
                CachedNetworkImage(
                  imageUrl: url,
                  fit: BoxFit.cover,
                  cacheManager: PosterCacheManager(),
                  placeholder: (context, _) =>
                      widget.loadingPlaceholder ?? widget.placeholder,
                  errorWidget: (context, _, __) => widget.placeholder,
                )
              else
                widget.placeholder,
              ...widget.overlays,
              if (widget.hoverOverlay != null)
                AnimatedOpacity(
                  opacity: _isHovered ? 1.0 : 0.0,
                  duration: motion,
                  curve: DepthTokens.curveEmphasized,
                  child: widget.hoverOverlay,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The neutral play affordance revealed when hovering a grid poster.
///
/// Shared by the library grid ([MediaPoster]) and search results
/// (`SearchResultCard`), which must read identically. The home rails
/// (`MediaCard`) deliberately use a glassier treatment of their own, so they do
/// not use this.
///
/// This exists because an earlier revision left each grid surface with its own
/// private copy of this scrim, which is the same duplication that let the
/// search card drift away from the library card in the first place.
class PosterPlayScrim extends StatelessWidget {
  const PosterPlayScrim({super.key});

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.overlayDark,
      child: Center(
        child: Icon(
          Icons.play_circle_filled,
          size: 48,
          color: AppColors.textPrimary,
        ),
      ),
    );
  }
}
