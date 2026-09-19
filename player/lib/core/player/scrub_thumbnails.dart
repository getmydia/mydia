import 'package:flutter/foundation.dart';

import 'thumbnail_service.dart';

/// The trickplay frames for the file that is playing, loaded on demand.
///
/// Fetched on the first scrub, not when playback opens: most viewers never
/// scrub, and the VTT request is wasted on them. Notifies once, when cues
/// arrive, so a bubble already on screen can add its frame.
class ScrubThumbnails extends ChangeNotifier {
  ScrubThumbnails({required ThumbnailService service, required this.fileId})
      : _service = service;

  final ThumbnailService _service;
  final String fileId;

  List<ThumbnailCue> _cues = const [];
  bool _requested = false;
  bool _disposed = false;

  String get spriteUrl => _service.spriteUrl(fileId);

  Map<String, String> get imageHeaders => _service.imageHeaders;

  /// Starts the one fetch this file gets. Later calls do nothing.
  void ensureLoaded() {
    if (_requested) return;
    _requested = true;
    _service.fetchThumbnails(fileId).then((cues) {
      if (_disposed || cues.isEmpty) return;
      _cues = cues;
      notifyListeners();
    });
  }

  /// The frame for [position], or null before cues have arrived or when the
  /// file has none.
  ThumbnailCue? cueAt(Duration position) =>
      _service.cueFor(_cues, position.inMilliseconds / 1000);

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
