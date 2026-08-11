import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/layout/breakpoints.dart';
import '../../../core/theme/colors.dart';
import '../../../domain/models/media_stream.dart';
import 'media_info_content.dart';
import 'media_info_controller.dart';

/// Which detail screen the panel was opened from.
enum MediaInfoTarget { movie, episode }

/// The panel body: version state plus the readout.
///
/// Separate from the sheet so widget tests can pump it without a navigator or
/// a GraphQL client.
class MediaInfoPanel extends StatefulWidget {
  final List<MediaFileInfo> files;

  const MediaInfoPanel({super.key, required this.files});

  @override
  State<MediaInfoPanel> createState() => _MediaInfoPanelState();
}

class _MediaInfoPanelState extends State<MediaInfoPanel> {
  int _selected = 0;

  @override
  Widget build(BuildContext context) {
    // Below the desktop breakpoint the panel is a bottom sheet; at or above it
    // is a right-hand side panel, so the backdrop and poster stay visible.
    final isWide = Breakpoints.isDesktop(context);

    return _PanelSurface(
      key: isWide
          ? const Key('media-info-side')
          : const Key('media-info-bottom'),
      child: Column(
        mainAxisSize: isWide ? MainAxisSize.max : MainAxisSize.min,
        children: [
          if (isWide) const SizedBox(height: 12) else const _Grabber(),
          const _PanelHeader(),
          Flexible(
            fit: isWide ? FlexFit.tight : FlexFit.loose,
            child: MediaInfoContent(
              files: widget.files,
              selectedIndex: _selected,
              onSelectVersion: (index) => setState(() => _selected = index),
            ),
          ),
        ],
      ),
    );
  }
}

/// The panel's background, border, radius and width, for every state.
///
/// A [Material] rather than a decorated [Container]: `showGeneralDialog`'s page
/// has no Material ancestor, and without one every [Text] inherits Flutter's
/// fallback debug style (a yellow double underline) and every [InkWell] fails
/// `debugCheckHasMaterial`. Owning the width here also means the loading, error
/// and loaded states cannot disagree about it and make the panel jump.
class _PanelSurface extends StatelessWidget {
  final Widget child;

  const _PanelSurface({super.key, required this.child});

  /// Side-panel width.
  ///
  /// `Breakpoints.isDesktop` is `width >= 900` despite its name, so a flat
  /// fraction would make the panel *narrower* than the 420 it shipped with on
  /// small laptops. The floor keeps every viewport at least as wide as before;
  /// the ceiling stops it sprawling on an ultrawide.
  static double sideWidth(BuildContext context) =>
      (MediaQuery.sizeOf(context).width * 0.4).clamp(420.0, 520.0);

  @override
  Widget build(BuildContext context) {
    final isWide = Breakpoints.isDesktop(context);

    return Material(
      color: AppColors.surface,
      borderRadius:
          isWide ? null : const BorderRadius.vertical(top: Radius.circular(16)),
      clipBehavior: Clip.antiAlias,
      child: Container(
        width: isWide ? sideWidth(context) : double.infinity,
        height: isWide ? double.infinity : null,
        constraints: isWide
            ? null
            : BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * 0.78,
              ),
        decoration: isWide
            ? const BoxDecoration(
                border: Border(left: BorderSide(color: AppColors.border)),
              )
            : null,
        child: child,
      ),
    );
  }
}

class _Grabber extends StatelessWidget {
  const _Grabber();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 40,
      height: 4,
      margin: const EdgeInsets.only(top: 10, bottom: 4),
      decoration: BoxDecoration(
        color: AppColors.border,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _PanelHeader extends StatelessWidget {
  const _PanelHeader();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 6, 10, 6),
      child: Row(
        children: [
          const Expanded(
            child: Text(
              'Media Info',
              style: TextStyle(
                color: AppColors.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            key: const Key('media-info-close'),
            icon:
                const Icon(Icons.close_rounded, color: AppColors.textSecondary),
            onPressed: () => Navigator.of(context).maybePop(),
            tooltip: 'Close',
          ),
        ],
      ),
    );
  }
}

/// Opens the Media Info panel for a movie or episode.
///
/// Focus is trapped inside the panel in both layouts so TV remote navigation
/// cannot walk out of it into the detail screen underneath.
Future<void> showMediaInfo({
  required BuildContext context,
  required String id,
  required MediaInfoTarget target,
}) {
  final isWide = Breakpoints.isDesktop(context);

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Media Info',
    barrierColor: isWide ? Colors.black26 : Colors.black54,
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (dialogContext, _, __) {
      return FocusScope(
        autofocus: true,
        child: Align(
          alignment: isWide ? Alignment.centerRight : Alignment.bottomCenter,
          child: Consumer(
            builder: (consumerContext, ref, _) {
              final async =
                  ref.watch(mediaInfoProvider((id: id, target: target)));

              return async.when(
                loading: () => const _PanelShell(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(child: CircularProgressIndicator()),
                  ),
                ),
                error: (_, __) => _PanelShell(
                  child: _ErrorBody(
                    onRetry: () => ref.invalidate(
                      mediaInfoProvider((id: id, target: target)),
                    ),
                  ),
                ),
                data: (files) => MediaInfoPanel(files: files),
              );
            },
          ),
        ),
      );
    },
    transitionBuilder: (_, animation, __, child) {
      final begin = isWide ? const Offset(1, 0) : const Offset(0, 1);
      return SlideTransition(
        position: Tween<Offset>(begin: begin, end: Offset.zero).animate(
          CurvedAnimation(parent: animation, curve: Curves.easeOutCubic),
        ),
        child: child,
      );
    },
  );
}

class _PanelShell extends StatelessWidget {
  final Widget child;

  const _PanelShell({required this.child});

  @override
  Widget build(BuildContext context) {
    return _PanelSurface(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [const _PanelHeader(), child],
      ),
    );
  }
}

class _ErrorBody extends StatelessWidget {
  final VoidCallback onRetry;

  const _ErrorBody({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 8, 18, 28),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Media info could not be loaded. Check your connection to the server.',
            style: TextStyle(
                color: AppColors.textSecondary, fontSize: 13, height: 1.5),
          ),
          const SizedBox(height: 14),
          TextButton(
            key: const Key('media-info-retry'),
            onPressed: onRetry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}
