import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../core/cache/poster_cache_manager.dart';
import '../../core/theme/colors.dart';
import '../../core/ui/reduced_motion.dart';

/// A shell-level ambient backdrop: a pre-blurred, dimmed copy of the focused
/// title's artwork that crossfades behind the browse screens.
///
/// Performance (plan R2/R11): the blur is a **pre-blurred image layer**
/// ([ImageFiltered] over a [CachedNetworkImage]), *not* a live full-screen
/// [BackdropFilter] behind scrolling content. The blurred layer is computed
/// once and is not recomputed while content scrolls in front of it. The whole
/// backdrop is wrapped in a [RepaintBoundary] so it repaints independently of
/// the foreground.
///
/// A constant dark base always paints behind the [AnimatedSwitcher] so the
/// scrim never dips to a brighter color mid-crossfade, and the incoming image
/// is pre-warmed with [precacheImage] before the key swaps to avoid a decode
/// hitch.
///
/// When [imageUrl] is null (grid/settings screens) a calm static gradient is
/// shown with no network image. All motion collapses to [Duration.zero] when
/// the user prefers reduced motion (see [ReducedMotion]).
class AmbientBackdrop extends StatefulWidget {
  /// The artwork URL to blur behind content. When null, the static fallback
  /// gradient is rendered (no image is fetched).
  final String? imageUrl;

  /// Stable identity of the artwork. Drives the [AnimatedSwitcher] crossfade:
  /// the layer transitions only when [id] changes. When null, the fallback is
  /// treated as a single stable layer.
  final String? id;

  /// Sigma of the gaussian blur applied to the artwork.
  final double blurSigma;

  /// Crossfade duration when artwork changes (collapsed to zero under reduced
  /// motion).
  final Duration crossfadeDuration;

  const AmbientBackdrop({
    super.key,
    this.imageUrl,
    this.id,
    this.blurSigma = 40,
    this.crossfadeDuration = const Duration(milliseconds: 600),
  });

  @override
  State<AmbientBackdrop> createState() => _AmbientBackdropState();
}

class _AmbientBackdropState extends State<AmbientBackdrop> {
  @override
  void didUpdateWidget(covariant AmbientBackdrop oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Pre-warm the incoming artwork before the AnimatedSwitcher key swaps so
    // the crossfade does not stall on first decode (plan U4 / R2).
    final url = widget.imageUrl;
    if (url != null && url != oldWidget.imageUrl) {
      precacheImage(
        CachedNetworkImageProvider(url, cacheManager: BackdropCacheManager()),
        context,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final reduceMotion = context.reduceMotion;
    final duration = reduceMotion ? Duration.zero : widget.crossfadeDuration;

    return RepaintBoundary(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Constant dark base so the scrim never brightens mid-crossfade.
          const ColoredBox(color: AppColors.background),
          AnimatedSwitcher(
            duration: duration,
            // Keep both layers stacked during the fade so the outgoing artwork
            // does not pop out before the incoming one is opaque.
            layoutBuilder: (currentChild, previousChildren) => Stack(
              fit: StackFit.expand,
              children: [
                ..._dedupedByKey(previousChildren, currentChild),
                if (currentChild != null) currentChild,
              ],
            ),
            child: _buildLayer(context),
          ),
        ],
      ),
    );
  }

  /// Drops outgoing layers whose key is already spoken for, keeping the most
  /// recent one per key.
  ///
  /// The fallback layer carries a constant key, so hovering across a poster
  /// grid — which flips the source artwork <-> none on every mouse enter and
  /// leave, far faster than [crossfadeDuration] — parks several identically
  /// keyed fallback layers in the switcher at once. [AnimatedSwitcher] only
  /// filters outgoing children against the *current* child's key
  /// (`animated_switcher.dart`, `build`), never against each other, so those
  /// duplicates reach the [Stack] below and trip its duplicate-key assertion.
  /// That assertion corrupts the element tree (`_dependents.isEmpty`, then
  /// duplicate `GlobalKey`) and replaces the whole shell subtree with an
  /// [ErrorWidget] — every browse screen renders as an error box.
  static Iterable<Widget> _dedupedByKey(
    List<Widget> previousChildren,
    Widget? currentChild,
  ) {
    final seen = <Key?>{if (currentChild != null) currentChild.key};
    // Outgoing children are ordered oldest-first, so walk in reverse to keep
    // the newest layer of each key — the one that just started fading and is
    // still the most opaque — then restore paint order.
    return [
      for (final child in previousChildren.reversed)
        if (seen.add(child.key)) child,
    ].reversed;
  }

  Widget _buildLayer(BuildContext context) {
    final url = widget.imageUrl;
    if (url == null || url.isEmpty) {
      // Calm static fallback — no network image (plan U4 / AE3).
      return const _StaticFallback(key: ValueKey('ambient-fallback'));
    }

    return _ArtworkLayer(
      key: ValueKey('ambient-${widget.id ?? url}'),
      imageUrl: url,
      blurSigma: widget.blurSigma,
    );
  }
}

/// A single blurred, dimmed artwork layer. The blur is pre-applied with
/// [ImageFiltered] (never a live [BackdropFilter]).
class _ArtworkLayer extends StatelessWidget {
  final String imageUrl;
  final double blurSigma;

  const _ArtworkLayer({
    super.key,
    required this.imageUrl,
    required this.blurSigma,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(
            sigmaX: blurSigma,
            sigmaY: blurSigma,
            tileMode: TileMode.decal,
          ),
          child: CachedNetworkImage(
            imageUrl: imageUrl,
            fit: BoxFit.cover,
            cacheManager: BackdropCacheManager(),
            // No placeholder/error chrome: the constant dark base behind the
            // switcher covers the gap, keeping the scrim color stable.
            placeholder: (_, __) => const SizedBox.expand(),
            errorWidget: (_, __, ___) => const SizedBox.expand(),
          ),
        ),
        // Dark scrim guaranteeing text contrast over bright artwork. Alpha is
        // tuned in U8 (see AmbientBackdropScrim.baseDim).
        const AmbientBackdropScrim(),
      ],
    );
  }
}

/// Dark scrim painted over the blurred artwork to guarantee foreground text
/// contrast (plan R3 / U8). A flat dim plus a slightly stronger bottom gradient
/// keeps content legible without crushing the artwork to pure black.
///
/// [baseColor] and [baseDim] are the single source of truth for the scrim's
/// colour and top-of-scrim alpha, and both are asserted against worst-case
/// bright artwork in `ambient_backdrop_contrast_test`. Naming only the alpha
/// here is what let the base colour drift to a navy literal unnoticed.
class AmbientBackdropScrim extends StatelessWidget {
  const AmbientBackdropScrim({super.key});

  /// Base colour of the scrim, before [baseDim] / [bottomDim] are applied.
  ///
  /// Sourced from the palette rather than written as a literal. The previous
  /// hardcoded navy survived the move to the neutral palette precisely because
  /// nothing tied it to a token, and it tinted every Home backdrop blue. Same
  /// arrangement as `DepthTokens.playerChromeTint`, for the same reason.
  static const Color baseColor = AppColors.background;

  /// Top-of-scrim dim alpha applied over the blurred artwork. Tuned in U8 so
  /// primary text clears WCAG AAA (7:1) and secondary text clears AA (4.5:1)
  /// over worst-case (white) artwork; on the flat theme background they remain
  /// at their ~15:1 / ~7:1 design targets.
  static const double baseDim = 0.88;

  /// Bottom-of-scrim dim alpha (slightly stronger to anchor bottom content).
  static const double bottomDim = 0.94;

  @override
  Widget build(BuildContext context) {
    // Not a const expression: `withValues` is an instance method, so the
    // decoration is built here rather than inlined as const colour literals.
    // The widget itself is still const-constructed by its caller, so this runs
    // once per mount rather than per frame.
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            baseColor.withValues(alpha: baseDim),
            baseColor.withValues(alpha: bottomDim),
          ],
          stops: const [0.0, 1.0],
        ),
      ),
    );
  }
}

/// Calm static gradient shown for grids / settings (no per-title artwork).
class _StaticFallback extends StatelessWidget {
  const _StaticFallback({super.key});

  @override
  Widget build(BuildContext context) {
    return const DecoratedBox(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: Alignment(0, -0.6),
          radius: 1.4,
          colors: [
            AppColors.surface,
            AppColors.background,
          ],
          stops: [0.0, 1.0],
        ),
      ),
    );
  }
}
