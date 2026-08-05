import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
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

  /// Captured eagerly in [initState], rather than read fresh via [ref] from
  /// [dispose].
  ///
  /// Riverpod's own `ref` surface throws once a widget starts unmounting —
  /// confirmed empirically: `ref.read` from [dispose] raises "Using ref when
  /// a widget is about to or has been unmounted is unsafe" as soon as any
  /// listener is attached to the provider, which is always true in the real
  /// app since the shell watches it for the backdrop crossfade. Riverpod's
  /// own error message for this is to save the provider state in a field
  /// instead, which is what this does: the notifier instance itself remains
  /// safe to call after unmount, only the [ref] accessor is not. A `late
  /// final` field initializer would evaluate lazily on first read — which,
  /// for a poster that is never hovered until it is disposed, is *inside*
  /// [dispose] itself, defeating the point — so this is assigned eagerly in
  /// [initState] instead.
  late final AmbientBackdropController _backdropController;

  bool get _hasArtwork {
    final url = widget.imageUrl;
    return url != null && url.isNotEmpty;
  }

  @override
  void initState() {
    super.initState();
    _backdropController = ref.read(ambientBackdropControllerProvider.notifier);
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
  void didUpdateWidget(covariant PosterFrame oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A hovered element can be recycled onto different data under a
    // stationary cursor (a scrolling grid, say), which fires neither onEnter
    // nor onExit. Without this, the backdrop would stay pinned to whichever
    // poster last triggered a real hover event.
    if (_isHovered && widget.imageUrl != oldWidget.imageUrl) {
      final hasArtwork = _hasArtwork;
      final url = widget.imageUrl;
      // What this instance previously had published, in case the no-artwork
      // branch below needs to retract exactly that (and nothing fresher).
      final previous = BackdropSource(
        imageUrl: oldWidget.imageUrl,
        id: oldWidget.imageUrl,
      );
      // didUpdateWidget runs while the widget tree is still building, and
      // Riverpod forbids writing provider state synchronously from there
      // (confirmed empirically: it throws "Tried to modify a provider while
      // the widget tree was building"). Deferring to a post-frame callback
      // mirrors publishBackdropSource just below, which defers for the same
      // reason.
      SchedulerBinding.instance.addPostFrameCallback((_) {
        // The pointer may have left this poster between scheduling and now —
        // MouseTracker dispatches enter/exit from its own post-frame phase,
        // and its ordering against this callback is not guaranteed, so
        // _handleHoverExit may already have cleared the override. Without
        // this guard we'd re-assert artwork for a poster nobody is hovering.
        if (!mounted || !_isHovered) return;
        if (hasArtwork) {
          // No identity check needed: _isHovered still true at this point
          // means the pointer is genuinely on this poster, so asserting its
          // artwork is correct regardless of what else raced.
          _backdropController.setHover(BackdropSource(imageUrl: url, id: url));
        } else {
          // The new data has no artwork; a bare clearHover() would risk the
          // same race dispose() guards against — a different poster's fresh
          // override arriving before this callback runs. Only retract what
          // this instance itself last published.
          _backdropController.clearHoverIf(previous);
        }
      });
    }
  }

  @override
  void dispose() {
    // MouseRegion's onExit is not guaranteed to fire when the region is
    // unmounted while hovered (scrolling a hovered poster out of the tree,
    // navigating away). Clear any override this instance published so it
    // doesn't strand the backdrop on artwork no longer on screen.
    //
    // This cannot call _backdropController.clearHover() directly here, even
    // via the captured controller (which sidesteps the separate ref-unsafety
    // issue documented on that field). Confirmed empirically: `dispose` is
    // itself one of the widget life-cycles Riverpod forbids synchronous
    // provider writes from — unmounting runs inside BuildOwner.finalizeTree's
    // build lock, and writing there throws "Tried to modify a provider while
    // the widget tree was building" regardless of how the notifier was
    // obtained. So this defers, the same way publishBackdropSource and
    // didUpdateWidget above do.
    if (_isHovered) {
      // Identity-checked, not a bare clearHover(): this scroll-recycling
      // scenario is exactly what didUpdateWidget above exists for — this
      // poster can be disposed-while-hovered (onExit never fired, which is
      // the bug this file fixes) in the same frame a different poster
      // scrolls in under the stationary cursor and publishes its own hover
      // override. If our deferred clear ran unconditionally, it could land
      // after that fresh publish and wipe it, leaving the backdrop on the
      // default while a poster is visibly hovered — the same class of
      // staleness bug, polarity reversed. clearHoverIf only clears when the
      // override still equals what this instance published.
      final source =
          BackdropSource(imageUrl: widget.imageUrl, id: widget.imageUrl);
      SchedulerBinding.instance.addPostFrameCallback((_) {
        _backdropController.clearHoverIf(source);
      });
    }
    super.dispose();
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
