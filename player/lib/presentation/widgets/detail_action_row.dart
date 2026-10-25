import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/liquid_glass/glass_style.dart';
import '../../core/theme/palette.dart';
import '../../l10n/l10n.dart';
import 'focus_highlight.dart';
import 'glass/glass_interaction.dart';
import 'glass_surface.dart';
import 'toast/toaster.dart';

/// Width of one action's slot when the row is [DetailActionRow.compact]. Wide
/// enough for the longest label ("Download") at the label size with air on
/// both sides.
const double _kActionSlotWidth = 64;

/// Action row in the detail body, below the hero: mark watched/unwatched,
/// favorite, download, open the trailer on YouTube when one exists, and open
/// the Media Info panel when the title has files. Shared between the movie and
/// TV show detail screens, since both need the identical row.
class DetailActionRow extends StatelessWidget {
  final bool watched;
  final VoidCallback onToggleWatched;
  final bool isFavorite;
  final VoidCallback? onToggleFavorite;
  final VoidCallback? onDownload;
  final String? trailerUrl;

  /// Whether to show the Download button at all. Defaults to `true`; callers
  /// on platforms without download support (e.g. gated by
  /// `isDownloadSupported`) pass `false` to hide it entirely rather than
  /// showing a button that can never do anything.
  final bool showDownload;

  /// Whether this title is already downloaded. Defaults to `false`; callers
  /// pass the current download state so the button reads as done (a filled
  /// check icon in the success colour) instead of inviting a download that
  /// only produces an "Already downloaded" toast — the state the
  /// pre-redesign app-bar download button used to show.
  final bool isDownloaded;

  /// Opens the Media Info panel. Null hides the action, which is what callers
  /// pass when the title has no files to describe.
  final VoidCallback? onShowMediaInfo;

  /// Whether the row shrink-wraps to fixed-width slots instead of spreading
  /// across its parent. Defaults to `false`, which suits a phone-width column
  /// where the row should span edge to edge. Wide layouts pass `true` so the
  /// row takes only the width its buttons need, however many are showing.
  final bool compact;

  /// False hides Watched, for a server that cannot record it.
  final bool showWatched;

  /// False hides Favorite, for a server without favorites.
  final bool showFavorite;

  const DetailActionRow({
    super.key,
    required this.watched,
    required this.onToggleWatched,
    required this.isFavorite,
    this.onToggleFavorite,
    this.onDownload,
    required this.trailerUrl,
    this.showDownload = true,
    this.isDownloaded = false,
    this.onShowMediaInfo,
    this.compact = false,
    this.showWatched = true,
    this.showFavorite = true,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final trailerUrl = this.trailerUrl;
    final actions = <Widget>[
      if (showWatched)
        _ActionButton(
          icon: watched
              ? Icons.check_circle_rounded
              : Icons.check_circle_outline_rounded,
          label: context.l10n.commonWatched,
          highlighted: watched,
          highlightColor: AppColors.success,
          onTap: onToggleWatched,
        ),
      if (showFavorite && onToggleFavorite != null)
        _ActionButton(
          icon: isFavorite
              ? Icons.favorite_rounded
              : Icons.favorite_border_rounded,
          label: context.l10n.commonFavorite,
          highlighted: isFavorite,
          highlightColor: AppColors.error,
          onTap: onToggleFavorite!,
        ),
      if (showDownload && onDownload != null)
        _ActionButton(
          icon: isDownloaded
              ? Icons.download_done_rounded
              : Icons.download_rounded,
          label: context.l10n.commonDownload,
          highlighted: isDownloaded,
          highlightColor: AppColors.success,
          onTap: onDownload!,
        ),
      if (trailerUrl != null)
        _ActionButton(
          icon: Icons.smart_display_rounded,
          label: context.l10n.detailTrailer,
          highlighted: false,
          highlightColor: palette.primary,
          onTap: () => _openTrailer(context, trailerUrl),
        ),
      if (onShowMediaInfo != null)
        _ActionButton(
          icon: Icons.info_outline_rounded,
          label: context.l10n.detailInfo,
          highlighted: false,
          highlightColor: palette.textPrimary,
          onTap: onShowMediaInfo!,
        ),
    ];

    final row = Row(
      mainAxisSize: compact ? MainAxisSize.min : MainAxisSize.max,
      children: [
        for (final action in actions)
          compact
              ? SizedBox(width: _kActionSlotWidth, child: action)
              : Expanded(child: action),
      ],
    );
    // One backdrop pass shared by every glass circle in the row.
    return GlassStyle.of(context) ? BackdropGroup(child: row) : row;
  }

  Future<void> _openTrailer(BuildContext context, String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;

    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      showToast(context, context.l10n.detailTrailerOpenFailed,
          kind: ToastKind.error);
    }
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool highlighted;
  final Color highlightColor;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.highlighted,
    required this.highlightColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    final color = highlighted ? highlightColor : palette.textPrimary;
    final glass = GlassStyle.of(context);
    final iconWidget = Center(child: Icon(icon, color: color, size: 20));
    final circle = SizedBox.square(
      dimension: 44,
      child: glass
          ? GlassSurface.control(
              borderRadius: BorderRadius.circular(22),
              grouped: true,
              child: iconWidget,
            )
          : GlassSurface.faux(
              fillColor: highlighted
                  ? highlightColor.withValues(alpha: 0.15)
                  : Colors.white.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(22),
              showRim: false,
              child: iconWidget,
            ),
    );

    return FocusHighlight(
      onActivate: onTap,
      borderRadius: const BorderRadius.all(Radius.circular(12)),
      child: InkWell(
        onTap: onTap,
        // FocusHighlight above is the single focus stop for this chip.
        // InkWell defaults canRequestFocus to true, which would otherwise
        // register a second, invisible focus stop nested inside the first.
        canRequestFocus: false,
        splashFactory: glass ? NoSplash.splashFactory : null,
        borderRadius: BorderRadius.circular(22),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            glass ? GlassInteraction(child: circle) : circle,
            const SizedBox(height: 6),
            Text(
              label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.fade,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 10.5, color: palette.textSecondary),
            ),
          ],
        ),
      ),
    );
  }
}
