import 'package:flutter/material.dart';

import '../../core/theme/colors.dart';
import '../../domain/models/download_option.dart';

/// Dialog for choosing what to download before a download starts.
///
/// Shows the options the source offers (1080p, 720p, original) with estimated
/// file sizes, handling loading and error states. A source that offers only
/// its original file gets a plain confirmation instead of a list of one.
class QualityDownloadDialog extends StatefulWidget {
  final String title;
  final Future<List<DownloadOption>> options;

  const QualityDownloadDialog({
    super.key,
    required this.title,
    required this.options,
  });

  @override
  State<QualityDownloadDialog> createState() => _QualityDownloadDialogState();
}

class _QualityDownloadDialogState extends State<QualityDownloadDialog> {
  String? _selectedResolution;
  bool _isStartingDownload = false;

  static bool _isLoneOriginal(List<DownloadOption> options) =>
      options.length == 1 && options.first.resolution == 'original';

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<DownloadOption>>(
      future: widget.options,
      builder: (context, snapshot) => _buildDialog(context, snapshot),
    );
  }

  Widget _buildDialog(
    BuildContext context,
    AsyncSnapshot<List<DownloadOption>> snapshot,
  ) {
    return AlertDialog(
      backgroundColor: AppColors.surface,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Download Quality',
            style: Theme.of(context).textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 4),
          Text(
            widget.title,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: switch (snapshot) {
          AsyncSnapshot(hasError: true, :final error) =>
            _buildErrorContent(context, error!),
          AsyncSnapshot(hasData: true, :final data) =>
            _buildOptionsContent(context, data!),
          _ => _buildLoadingContent(),
        },
      ),
      actions: _buildActions(context, snapshot.data),
    );
  }

  Widget _buildOptionsContent(
      BuildContext context, List<DownloadOption> options) {
    if (options.isEmpty) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(
            Icons.warning_amber_rounded,
            size: 48,
            color: AppColors.warning,
          ),
          const SizedBox(height: 12),
          Text(
            'No download options available',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: AppColors.textSecondary,
                ),
            textAlign: TextAlign.center,
          ),
        ],
      );
    }

    if (_isLoneOriginal(options)) {
      final option = options.first;
      final container = option.container;
      return Text(
        'Download original, ${option.formattedSize}'
        '${container == null ? '' : ' ${container.toUpperCase()}'}?',
        key: const Key('download-confirm-original'),
        style: Theme.of(context).textTheme.bodyMedium,
      );
    }

    // Sort options: pre-transcoded first, then by resolution
    final sortedOptions = List<DownloadOption>.from(options)
      ..sort((a, b) {
        // Pre-transcoded options first
        if (a.isPreTranscoded && !b.isPreTranscoded) return -1;
        if (!a.isPreTranscoded && b.isPreTranscoded) return 1;
        return 0;
      });

    // Pre-select the best option: prefer pre-transcoded, fallback to first
    if (_selectedResolution == null && sortedOptions.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          final preTranscoded =
              sortedOptions.where((o) => o.isPreTranscoded).toList();
          setState(() {
            _selectedResolution = preTranscoded.isNotEmpty
                ? preTranscoded.first.resolution
                : sortedOptions.first.resolution;
          });
        }
      });
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Select Quality',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 12),
        ...sortedOptions.map((option) => _buildQualityOption(option)),
      ],
    );
  }

  Widget _buildQualityOption(DownloadOption option) {
    final isSelected = _selectedResolution == option.resolution;

    return InkWell(
      key: Key('download-option-${option.resolution}'),
      onTap: _isStartingDownload
          ? null
          : () {
              setState(() {
                _selectedResolution = option.resolution;
              });
            },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected
              ? AppColors.primary.withValues(alpha: 0.2)
              : AppColors.surfaceVariant,
          border: Border.all(
            color: isSelected ? AppColors.primary : Colors.transparent,
            width: 2,
          ),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(
              isSelected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              color: isSelected ? AppColors.primary : AppColors.textSecondary,
              size: 24,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        option.label,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                      if (option.isPreTranscoded) ...[
                        const SizedBox(width: 8),
                        _buildTranscodeBadge(option),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Text(
                        option.isPreTranscoded
                            ? option.formattedDisplaySize
                            : '~${option.formattedSize}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppColors.textSecondary,
                            ),
                      ),
                      if (option.isTranscoding) ...[
                        const SizedBox(width: 8),
                        _buildTranscodeBadge(option),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            if (isSelected)
              const Icon(
                Icons.check_circle,
                color: AppColors.primary,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildTranscodeBadge(DownloadOption option) {
    if (option.isPreTranscoded) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.success.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'Ready',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppColors.success,
                fontWeight: FontWeight.w600,
              ),
        ),
      );
    } else if (option.isTranscoding) {
      final progress = option.transcodeProgress ?? 0.0;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.warning.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          'Transcoding ${(progress * 100).toStringAsFixed(0)}%',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: AppColors.warning,
                fontWeight: FontWeight.w600,
              ),
        ),
      );
    }
    return const SizedBox.shrink();
  }

  Widget _buildLoadingContent() {
    return const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        CircularProgressIndicator(),
        SizedBox(height: 16),
        Text('Loading quality options...'),
      ],
    );
  }

  Widget _buildErrorContent(BuildContext context, Object error) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(
          Icons.error_outline,
          size: 48,
          color: AppColors.error,
        ),
        const SizedBox(height: 12),
        Text(
          'Failed to load options',
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          error.toString(),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppColors.textSecondary,
              ),
          textAlign: TextAlign.center,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  List<Widget> _buildActions(
    BuildContext context,
    List<DownloadOption>? options,
  ) {
    final hasOptions = options != null && options.isNotEmpty;
    final canDownload = hasOptions &&
        (_isLoneOriginal(options) || _selectedResolution != null) &&
        !_isStartingDownload;

    return [
      TextButton(
        onPressed:
            _isStartingDownload ? null : () => Navigator.of(context).pop(null),
        child: Text(
          'Cancel',
          style: TextStyle(
            color: _isStartingDownload
                ? AppColors.textDisabled
                : AppColors.textSecondary,
          ),
        ),
      ),
      ElevatedButton(
        onPressed: canDownload ? () => _startDownload(options) : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
          disabledBackgroundColor: AppColors.surfaceVariant,
          disabledForegroundColor: AppColors.textDisabled,
        ),
        child: _isStartingDownload
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              )
            : const Text('Download'),
      ),
    ];
  }

  /// Hands the choice back; the caller starts the download.
  void _startDownload(List<DownloadOption> options) {
    final chosen = _isLoneOriginal(options)
        ? options.first
        : options.where((o) => o.resolution == _selectedResolution).firstOrNull;
    if (chosen == null) return;

    setState(() {
      _isStartingDownload = true;
    });
    Navigator.of(context).pop(chosen);
  }
}

/// Shows the download dialog and returns the chosen option.
///
/// Returns null if the dialog was cancelled.
Future<DownloadOption?> pickDownloadOption(
  BuildContext context, {
  required String title,
  required Future<List<DownloadOption>> options,
}) =>
    showDialog<DownloadOption>(
      context: context,
      builder: (context) =>
          QualityDownloadDialog(title: title, options: options),
    );
