import 'package:flutter/material.dart';

import '../../core/player/best_file.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/media_file.dart';
import '../../domain/models/show_next_up.dart';
import 'next_up_labels.dart';
import 'play_button.dart';
import 'quality_selector.dart';

/// Below this many logical pixels of available width, the pill sheds its text.
/// Measured against the button row's own constraints, not the screen: the
/// poster and metadata column take a variable share of the hero.
const double kPillCollapseWidth = 380;

/// A composite play button that auto-selects the best file version
/// based on device/network context.
///
/// Layout: `[ quality label ]  [ ▶ ] [▼]`
///
/// The play button auto-selects the best file on mount. The dropdown
/// button (shown when multiple files exist) opens the quality selector
/// modal for manual override.
///
/// When [state] is supplied, the button renders as a labelled pill
/// (e.g. "Continue Watching") with a cue line underneath describing
/// [episode], collapsing to the plain icon form below [kPillCollapseWidth].
/// When [state] is null, the widget renders exactly as it always has: the
/// plain icon form with no label or cue line, so existing call sites
/// (movie/episode detail) are unaffected.
class SmartPlayButton extends StatefulWidget {
  final List<MediaFile> files;
  final void Function(MediaFile) onFileSelected;
  final NextUpState? state;

  /// Episode the cue line describes, supplied alongside [state].
  ///
  /// The cue line is composed here rather than by the caller because it names
  /// the resolution of the file that will actually play, and only this widget
  /// knows which file it picked.
  final NextUpEpisode? episode;

  const SmartPlayButton({
    super.key,
    required this.files,
    required this.onFileSelected,
    this.state,
    this.episode,
  });

  @override
  State<SmartPlayButton> createState() => _SmartPlayButtonState();
}

class _SmartPlayButtonState extends State<SmartPlayButton> {
  MediaFile? _selectedFile;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _detectBestFile();
  }

  Future<void> _detectBestFile() async {
    if (widget.files.isEmpty) return;

    final best = await pickBestFile(
      widget.files,
      MediaQuery.sizeOf(context).width,
    );
    if (mounted) setState(() => _selectedFile = best);
  }

  @override
  void didUpdateWidget(SmartPlayButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.files != widget.files) {
      _detectBestFile();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    if (state == null) return _buildIconForm(context);

    final episode = widget.episode;

    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < kPillCollapseWidth;
        // The icon form already prints the resolution next to the play
        // circle, so the compact cue line leaves it out. In the pill form the
        // cue line is the only place the resolution appears.
        final cueLine = episode == null
            ? null
            : nextUpCueLine(
                episode,
                state,
                resolution: compact ? null : _selectedFile?.resolution,
              );

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            compact ? _buildIconForm(context) : _buildPillForm(context),
            if (cueLine != null) ...[
              const SizedBox(height: 6),
              Text(
                compact ? '${nextUpShortLabel(state)} · $cueLine' : cueLine,
                style: const TextStyle(
                  fontSize: 12,
                  color: AppColors.textSecondary,
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildIconForm(BuildContext context) {
    final hasMultiple = widget.files.length > 1;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // Quality label
        if (_selectedFile != null) ...[
          Text(
            _selectedFile!.resolution ?? '',
            style: const TextStyle(
              fontSize: 11,
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 8),
        ],
        // Play button
        PlayButton(
          onPressed: _selectedFile != null
              ? () => widget.onFileSelected(_selectedFile!)
              : null,
        ),
        // Dropdown button (only when multiple files)
        if (hasMultiple) ...[
          const SizedBox(width: 6),
          _DropdownButton(
            onTap: () async {
              final picked = await showQualitySelector(context, widget.files);
              if (picked != null) {
                setState(() => _selectedFile = picked);
                widget.onFileSelected(picked);
              }
            },
          ),
        ],
      ],
    );
  }

  Widget _buildPillForm(BuildContext context) {
    final hasMultiple = widget.files.length > 1;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FilledButton.icon(
          onPressed: _selectedFile != null
              ? () => widget.onFileSelected(_selectedFile!)
              : null,
          icon: const Icon(Icons.play_arrow_rounded, size: 20),
          label: Text(nextUpLabel(widget.state!)),
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.primary,
            foregroundColor: AppColors.onPrimary,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            shape: const StadiumBorder(),
            textStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        if (hasMultiple) ...[
          const SizedBox(width: 6),
          _DropdownButton(
            onTap: () async {
              final picked = await showQualitySelector(context, widget.files);
              if (picked != null) {
                setState(() => _selectedFile = picked);
                widget.onFileSelected(picked);
              }
            },
          ),
        ],
      ],
    );
  }
}

class _DropdownButton extends StatelessWidget {
  final VoidCallback onTap;

  const _DropdownButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 28,
        height: 28,
        decoration: const BoxDecoration(
          shape: BoxShape.circle,
          // Neutral surface fill (no two-hue gradient) to match the system.
          color: AppColors.surfaceVariant,
        ),
        child: const Center(
          child: Icon(
            Icons.keyboard_arrow_down_rounded,
            size: 18,
            color: AppColors.textSecondary,
          ),
        ),
      ),
    );
  }
}
