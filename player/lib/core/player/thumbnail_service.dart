import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// One frame of a trickplay sprite sheet, as a WebVTT cue describes it.
class ThumbnailCue {
  /// Start time in seconds
  final double startTime;

  /// End time in seconds
  final double endTime;

  /// Sprite sheet filename as the VTT names it (the sheet's checksum)
  final String spriteFilename;

  /// X coordinate in the sprite sheet
  final int x;

  /// Y coordinate in the sprite sheet
  final int y;

  /// Width of the thumbnail
  final int width;

  /// Height of the thumbnail
  final int height;

  const ThumbnailCue({
    required this.startTime,
    required this.endTime,
    required this.spriteFilename,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  /// Check if this cue contains the given timestamp
  bool contains(double timestamp) {
    return timestamp >= startTime && timestamp < endTime;
  }
}

/// Fetches and reads the trickplay frames the server generates for a file.
///
/// The server writes one JPEG sheet per file (`sprite_generator.ex`: a 9x9
/// grid of 160x90 frames) and a WebVTT file mapping time ranges to `#xywh=`
/// regions of it. Both are served under `/api/v1/media/:id/` behind the
/// ordinary access token, so this works over a direct HTTP connection only:
/// the p2p local proxy forwards `/hls`, `/direct` and `/download` and nothing
/// else.
class ThumbnailService {
  final String serverUrl;
  final String authToken;
  final http.Client _client;

  /// Parsed cues per file id. An empty list means the file has none.
  final Map<String, List<ThumbnailCue>> _cache = {};

  ThumbnailService({
    required this.serverUrl,
    required this.authToken,
    http.Client? client,
  }) : _client = client ?? http.Client();

  /// Headers the sprite image request must carry.
  Map<String, String> get imageHeaders =>
      {'Authorization': 'Bearer $authToken'};

  /// The sprite sheet for [fileId].
  ///
  /// The name the VTT gives the sheet is its checksum, which is not a path
  /// the server serves; the sheet is always this endpoint.
  String spriteUrl(String fileId) =>
      '$serverUrl/api/v1/media/$fileId/thumbnails.jpg';

  /// The cues for [fileId], or an empty list when there are none or the
  /// request failed. Never throws.
  ///
  /// A 404 is remembered, since the file has no sprites and asking again
  /// would get the same answer. Any other failure is not.
  Future<List<ThumbnailCue>> fetchThumbnails(String fileId) async {
    final cached = _cache[fileId];
    if (cached != null) return cached;

    try {
      final response = await _client.get(
        Uri.parse('$serverUrl/api/v1/media/$fileId/thumbnails.vtt'),
        headers: {...imageHeaders, 'Accept': 'text/vtt'},
      );
      if (response.statusCode == 200) {
        return _cache[fileId] = parseVtt(response.body);
      }
      if (response.statusCode == 404) {
        return _cache[fileId] = const [];
      }
      debugPrint(
          '[ThumbnailService] thumbnails.vtt answered ${response.statusCode}');
      return const [];
    } catch (e) {
      debugPrint('[ThumbnailService] thumbnails.vtt failed: $e');
      return const [];
    }
  }

  /// The cue covering [seconds], or the nearest one when [seconds] falls in a
  /// gap. The generator skips the first and last 2% of the runtime, so the
  /// ends of the bar would otherwise have no frame. Null only for no cues.
  ThumbnailCue? cueFor(List<ThumbnailCue> cues, double seconds) {
    ThumbnailCue? nearest;
    var nearestDistance = double.infinity;
    for (final cue in cues) {
      if (cue.contains(seconds)) return cue;
      final distance = seconds < cue.startTime
          ? cue.startTime - seconds
          : seconds - cue.endTime;
      if (distance < nearestDistance) {
        nearest = cue;
        nearestDistance = distance;
      }
    }
    return nearest;
  }

  /// Parses WebVTT content into thumbnail cues.
  ///
  /// Expected format:
  /// ```
  /// WEBVTT
  ///
  /// 00:00:00.000 --> 00:00:05.000
  /// 3f9a1c.jpg#xywh=0,0,160,90
  /// ```
  @visibleForTesting
  static List<ThumbnailCue> parseVtt(String vttContent) {
    final cues = <ThumbnailCue>[];
    final lines = vttContent.split('\n');

    var i = 0;
    while (i < lines.length) {
      final line = lines[i].trim();

      if (line.isEmpty ||
          line.startsWith('WEBVTT') ||
          line.startsWith('NOTE')) {
        i++;
        continue;
      }

      if (line.contains('-->')) {
        final parts = line.split('-->');
        if (parts.length != 2) {
          i++;
          continue;
        }

        final startTime = _parseVttTime(parts[0].trim());
        final endTime = _parseVttTime(parts[1].trim());

        // The next line holds the sprite reference.
        i++;
        if (i >= lines.length) break;

        final spriteLine = lines[i].trim();
        if (spriteLine.isEmpty) continue;

        final cue = _parseSpriteLine(spriteLine, startTime, endTime);
        if (cue != null) cues.add(cue);
      }

      i++;
    }

    return cues;
  }

  /// `HH:MM:SS.mmm` to seconds.
  static double _parseVttTime(String timeStr) {
    final parts = timeStr.split(':');
    if (parts.length != 3) return 0.0;

    final hours = int.tryParse(parts[0]) ?? 0;
    final minutes = int.tryParse(parts[1]) ?? 0;
    final secondsParts = parts[2].split('.');
    final seconds = int.tryParse(secondsParts[0]) ?? 0;
    final millis =
        secondsParts.length > 1 ? int.tryParse(secondsParts[1]) ?? 0 : 0;

    return hours * 3600.0 + minutes * 60.0 + seconds + millis / 1000.0;
  }

  /// `name.jpg#xywh=0,0,160,90` to a cue, or null when malformed.
  static ThumbnailCue? _parseSpriteLine(
    String spriteLine,
    double startTime,
    double endTime,
  ) {
    final hashIndex = spriteLine.indexOf('#xywh=');
    if (hashIndex == -1) return null;

    final coords = spriteLine.substring(hashIndex + 6).split(',');
    if (coords.length != 4) return null;

    final values = coords.map(int.tryParse).toList();
    if (values.contains(null)) return null;

    return ThumbnailCue(
      startTime: startTime,
      endTime: endTime,
      spriteFilename: spriteLine.substring(0, hashIndex),
      x: values[0]!,
      y: values[1]!,
      width: values[2]!,
      height: values[3]!,
    );
  }
}
