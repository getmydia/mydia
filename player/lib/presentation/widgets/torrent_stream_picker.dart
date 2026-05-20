import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/colors.dart';
import '../../core/streaming/torrent_stream_providers.dart';
import '../../domain/models/torrent_candidate.dart';

class TorrentStreamPicker extends ConsumerStatefulWidget {
  final String contentType;
  final String contentId;
  final String title;

  const TorrentStreamPicker({
    super.key,
    required this.contentType,
    required this.contentId,
    required this.title,
  });

  @override
  ConsumerState<TorrentStreamPicker> createState() =>
      _TorrentStreamPickerState();
}

class _TorrentStreamPickerState extends ConsumerState<TorrentStreamPicker> {
  TorrentCandidate? _selectedCandidate;
  bool _isStarting = false;

  @override
  Widget build(BuildContext context) {
    final candidatesAsync = ref.watch(
      torrentCandidatesProvider(widget.contentType, widget.contentId),
    );

    return Container(
      padding: const EdgeInsets.symmetric(vertical: 20),
      decoration: const BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Stream from Torrent',
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
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Flexible(
            child: candidatesAsync.when(
              data: (candidates) => _buildCandidatesList(candidates),
              loading: () => _buildLoading(),
              error: (error, _) => _buildError(error),
            ),
          ),
          const SizedBox(height: 20),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed:
                        _isStarting ? null : () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                    onPressed: (_selectedCandidate == null || _isStarting)
                        ? null
                        : _startStreaming,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppColors.primary,
                      foregroundColor: AppColors.onPrimary,
                    ),
                    child: _isStarting
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              valueColor: AlwaysStoppedAnimation(Colors.white),
                            ),
                          )
                        : const Text('Stream'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCandidatesList(List<TorrentCandidate> candidates) {
    if (candidates.isEmpty) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Column(
            children: [
              Icon(Icons.search_off_rounded,
                  size: 48, color: AppColors.textSecondary),
              SizedBox(height: 16),
              Text('No torrents found for this item'),
            ],
          ),
        ),
      );
    }

    return ListView.separated(
      shrinkWrap: true,
      itemCount: candidates.length,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final candidate = candidates[index];
        final isSelected = _selectedCandidate == candidate;

        return InkWell(
          onTap: () => setState(() => _selectedCandidate = candidate),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: isSelected
                  ? AppColors.primary.withValues(alpha: 0.1)
                  : AppColors.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected ? AppColors.primary : Colors.transparent,
                width: 2,
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        candidate.title,
                        style: const TextStyle(fontWeight: FontWeight.bold),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          if (candidate.quality != null) ...[
                            _buildBadge(candidate.quality!, AppColors.primary),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            candidate.formattedSize,
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: AppColors.textSecondary,
                                    ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.arrow_upward_rounded,
                              size: 12, color: AppColors.success),
                          Text(
                            '${candidate.seeders ?? 0}',
                            style:
                                Theme.of(context).textTheme.bodySmall?.copyWith(
                                      color: AppColors.success,
                                    ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Indexer: ${candidate.indexer}',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: AppColors.textSecondary,
                            ),
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  const Icon(Icons.check_circle_rounded,
                      color: AppColors.primary),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBadge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }

  Widget _buildLoading() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(40),
        child: Column(
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Searching for torrents...'),
          ],
        ),
      ),
    );
  }

  Widget _buildError(Object error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          children: [
            const Icon(Icons.error_outline_rounded,
                size: 48, color: AppColors.error),
            const SizedBox(height: 16),
            Text('Error: $error', textAlign: TextAlign.center),
            TextButton(
              onPressed: () => ref.invalidate(torrentCandidatesProvider),
              child: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startStreaming() async {
    if (_selectedCandidate == null) return;

    setState(() => _isStarting = true);

    try {
      final service = await ref.read(torrentStreamServiceProvider.future);
      final sessionData = await service.startSession(
        magnetLink: _selectedCandidate!.magnetLink,
        releaseTitle: _selectedCandidate!.title,
        mediaItemId: widget.contentType == 'movie' ? widget.contentId : null,
        episodeId: widget.contentType == 'episode' ? widget.contentId : null,
      );

      if (mounted) {
        Navigator.pop(context, {
          'sessionId': sessionData['id'],
          'title': sessionData['title'],
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isStarting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to start stream: $e')),
        );
      }
    }
  }
}

Future<Map<String, dynamic>?> showTorrentStreamPicker(
  BuildContext context, {
  required String contentType,
  required String contentId,
  required String title,
}) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (context) => DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.9,
      expand: false,
      builder: (context, scrollController) => TorrentStreamPicker(
        contentType: contentType,
        contentId: contentId,
        title: title,
      ),
    ),
  );
}
