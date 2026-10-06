import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/p2p/media_proxy_factory.dart';
import '../../../core/router/legacy_routes.dart';
import '../../../core/sources/sources_providers.dart';
import '../../../domain/sources/item.dart';
import 'player_screen.dart';
import 'session/source_playback_sessions.dart';

/// Represents a single item in the playback queue.
class QueueItem {
  final String type;
  final String id;
  final String fileId;
  final String title;

  const QueueItem({
    required this.type,
    required this.id,
    required this.fileId,
    required this.title,
  });

  factory QueueItem.fromJson(Map<String, dynamic> json) {
    return QueueItem(
      type: json['type'] as String,
      id: json['id'] as String,
      fileId: json['file_id'] as String,
      title: json['title'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'type': type,
        'id': id,
        'file_id': fileId,
        'title': title,
      };
}

/// A player screen that handles queue-based playback for collections.
///
/// Decodes the queue from a base64-encoded JSON parameter and manages
/// navigation between items in the queue.
class QueuePlayerScreen extends ConsumerStatefulWidget {
  final String itemsParam;

  const QueuePlayerScreen({
    super.key,
    required this.itemsParam,
  });

  @override
  ConsumerState<QueuePlayerScreen> createState() => _QueuePlayerScreenState();
}

class _QueuePlayerScreenState extends ConsumerState<QueuePlayerScreen> {
  List<QueueItem> _queue = [];
  int _currentIndex = 0;
  String? _error;
  bool _showQueueOverlay = false;

  @override
  void initState() {
    super.initState();
    _decodeQueue();
  }

  void _decodeQueue() {
    try {
      // Decode base64 URL-safe encoded JSON
      final jsonString = utf8.decode(base64Url.decode(widget.itemsParam));
      final List<dynamic> jsonList = jsonDecode(jsonString) as List<dynamic>;

      setState(() {
        _queue = jsonList
            .map((item) => QueueItem.fromJson(item as Map<String, dynamic>))
            .toList();
        _error = null;
      });

      debugPrint('Queue decoded: ${_queue.length} items');
    } catch (e) {
      debugPrint('Error decoding queue: $e');
      setState(() {
        _error = 'Failed to decode queue: $e';
      });
    }
  }

  void _playNext() {
    if (_currentIndex < _queue.length - 1) {
      setState(() {
        _currentIndex++;
        _showQueueOverlay = false;
      });
    }
  }

  void _playPrevious() {
    if (_currentIndex > 0) {
      setState(() {
        _currentIndex--;
        _showQueueOverlay = false;
      });
    }
  }

  void _playAtIndex(int index) {
    if (index >= 0 && index < _queue.length) {
      setState(() {
        _currentIndex = index;
        _showQueueOverlay = false;
      });
    }
  }

  void _toggleQueueOverlay() {
    setState(() {
      _showQueueOverlay = !_showQueueOverlay;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline, size: 64, color: Colors.red),
              const SizedBox(height: 16),
              Text(
                _error!,
                style: const TextStyle(color: Colors.white),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/');
                  }
                },
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    if (_queue.isEmpty) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.queue_music, size: 64, color: Colors.grey),
              const SizedBox(height: 16),
              const Text(
                'Queue is empty',
                style: TextStyle(color: Colors.white, fontSize: 18),
              ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  if (context.canPop()) {
                    context.pop();
                  } else {
                    context.go('/');
                  }
                },
                child: const Text('Go Back'),
              ),
            ],
          ),
        ),
      );
    }

    final currentItem = _queue[_currentIndex];
    final sourceId = ref.watch(legacyMydiaSourceIdProvider);
    final source =
        sourceId == null ? null : ref.watch(mediaSourceProvider(sourceId));
    final session = source == null
        ? null
        : playbackSessionFor(
            source,
            ItemRef(
              sourceId: sourceId!,
              kind: currentItem.type == 'episode'
                  ? ItemKind.episode
                  : ItemKind.movie,
              externalId: currentItem.id,
            ),
            currentItem.fileId,
            proxy: () => ref.read(mediaProxyProvider),
          );
    if (session == null) {
      return const Scaffold(
        body: Center(
          key: Key('queue-player-unavailable'),
          child: Text('This server is not available to play from.'),
        ),
      );
    }
    final hasPrevious = _currentIndex > 0;
    final hasNext = _currentIndex < _queue.length - 1;

    return Stack(
      children: [
        // Main player - use key to force rebuild when switching items
        KeyedSubtree(
          key: ValueKey('player-${currentItem.id}-${currentItem.fileId}'),
          child: PlayerScreen(
            mediaType: currentItem.type,
            mediaId: currentItem.id,
            fileId: currentItem.fileId,
            title: currentItem.title,
            session: session,
          ),
        ),

        // Queue indicator badge (top right)
        Positioned(
          top: 8,
          right: 120,
          child: GestureDetector(
            onTap: _toggleQueueOverlay,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.7),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.queue_music, color: Colors.white, size: 18),
                  const SizedBox(width: 6),
                  Text(
                    '${_currentIndex + 1}/${_queue.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),

        // Queue navigation buttons (bottom center)
        Positioned(
          bottom: 80,
          left: 0,
          right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (hasPrevious)
                IconButton(
                  icon: const Icon(Icons.skip_previous,
                      color: Colors.white, size: 32),
                  onPressed: _playPrevious,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.7),
                    padding: const EdgeInsets.all(12),
                  ),
                  tooltip: 'Previous',
                ),
              if (hasPrevious && hasNext) const SizedBox(width: 24),
              if (hasNext)
                IconButton(
                  icon: const Icon(Icons.skip_next,
                      color: Colors.white, size: 32),
                  onPressed: _playNext,
                  style: IconButton.styleFrom(
                    backgroundColor: Colors.black.withValues(alpha: 0.7),
                    padding: const EdgeInsets.all(12),
                  ),
                  tooltip: 'Next',
                ),
            ],
          ),
        ),

        // Queue list overlay
        if (_showQueueOverlay) _buildQueueOverlay(),
      ],
    );
  }

  Widget _buildQueueOverlay() {
    return GestureDetector(
      onTap: _toggleQueueOverlay,
      child: Container(
        color: Colors.black.withValues(alpha: 0.8),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: _toggleQueueOverlay,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'Play Queue',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '${_queue.length} items',
                      style: TextStyle(
                        color: Colors.grey[400],
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),

              // Queue list
              Expanded(
                child: ListView.builder(
                  itemCount: _queue.length,
                  itemBuilder: (context, index) {
                    final item = _queue[index];
                    final isPlaying = index == _currentIndex;

                    return ListTile(
                      leading: Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: isPlaying
                              ? Colors.red
                              : Colors.grey.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Center(
                          child: isPlaying
                              ? const Icon(Icons.play_arrow,
                                  color: Colors.white, size: 24)
                              : Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ),
                      title: Text(
                        item.title,
                        style: TextStyle(
                          color: isPlaying ? Colors.red : Colors.white,
                          fontWeight:
                              isPlaying ? FontWeight.bold : FontWeight.normal,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        item.type == 'movie' ? 'Movie' : 'Episode',
                        style: TextStyle(
                          color: Colors.grey[500],
                          fontSize: 12,
                        ),
                      ),
                      onTap: () => _playAtIndex(index),
                      selected: isPlaying,
                      selectedTileColor: Colors.white.withValues(alpha: 0.1),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
