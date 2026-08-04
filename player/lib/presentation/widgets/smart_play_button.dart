import 'package:flutter/material.dart';

import '../../core/player/best_file.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/media_file.dart';
import 'play_button.dart';
import 'quality_selector.dart';

/// A composite play button that auto-selects the best file version
/// based on device/network context.
///
/// Layout: `[ quality label ]  [ ▶ ] [▼]`
///
/// The play button auto-selects the best file on mount. The dropdown
/// button (shown when multiple files exist) opens the quality selector
/// modal for manual override.
class SmartPlayButton extends StatefulWidget {
  final List<MediaFile> files;
  final void Function(MediaFile) onFileSelected;

  const SmartPlayButton({
    super.key,
    required this.files,
    required this.onFileSelected,
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
