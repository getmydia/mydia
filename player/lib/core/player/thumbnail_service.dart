import 'package:http/http.dart' as http;
import 'package:flutter/foundation.dart';

/// Represents a single thumbnail entry from the VTT file.
class ThumbnailCue {
  /// Start time in seconds
  final double startTime;

  /// End time in seconds
  final double endTime;

  /// Sprite sheet filename (checksum.jpg)
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

/// Service for fetching and parsing thumbnail VTT files for video scrubbing.
class ThumbnailService {
  final String serverUrl;
  final String authToken;

  /// Cache of parsed thumbnail data, keyed by file ID
  final Map<String, List<ThumbnailCue>> _cache = {};

  ThumbnailService({
    required this.serverUrl,
    required this.authToken,
  });

  /// Fetch and parse the VTT file for a media file.
  ///
  /// Parameters:
  ///   - fileId: The ID of the media file
  ///
  /// Returns a list of thumbnail cues, or an empty list if unavailable.
  Future<List<ThumbnailCue>> fetchThumbnails(String fileId) async {
    // Check cache first
    if (_cache.containsKey(fileId)) {
      return _cache[fileId]!;
    }

    try {
      final url = '$serverUrl/api/v1/media/$fileId/thumbnails.vtt';
      debugPrint('Fetching thumbnails from: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $authToken',
          'Accept': 'text/vtt',
        },
      );

      if (response.statusCode == 200) {
        final cues = _parseVtt(response.body);
        debugPrint('Parsed ${cues.length} thumbnail cues');

        // Cache the result
        _cache[fileId] = cues;

        return cues;
      } else if (response.statusCode == 404) {
        debugPrint('No thumbnails available for file: $fileId');
        // Cache empty result to avoid repeated requests
        _cache[fileId] = [];
        return [];
      } else {
        debugPrint('Failed to fetch thumbnails: ${response.statusCode}');
        return [];
      }
    } catch (e) {
      debugPrint('Error fetching thumbnails: $e');
      // Return empty list on error (graceful fallback)
      return [];
    }
  }

  /// Get the thumbnail cue for a specific timestamp.
  ///
  /// Returns null if no thumbnail is available for that timestamp.
  ThumbnailCue? getThumbnailForTime(List<ThumbnailCue> cues, double timestamp) {
    for (final cue in cues) {
      if (cue.contains(timestamp)) {
        return cue;
      }
    }
    return null;
  }

  /// Build the URL for the sprite sheet image.
  String getSpriteUrl(String spriteFilename) {
    // The sprite filename is the checksum with .jpg extension
    // Sprites are served from /generated/sprites/{tier1}/{tier2}/{checksum}.jpg
    final checksum = spriteFilename.replaceAll('.jpg', '');
    final tier1 = checksum.substring(0, 2);
    final tier2 = checksum.substring(2, 4);

    return '$serverUrl/generated/sprites/$tier1/$tier2/$spriteFilename';
  }

  /// Clear the cache
  void clearCache() {
    _cache.clear();
  }

  /// Parse WebVTT content into thumbnail cues.
  ///
  /// Expected format:
  /// ```
  /// WEBVTT
  ///
  /// 00:00:00.000 --> 00:00:05.000
  /// sprite.jpg#xywh=0,0,160,90
  ///
  /// 00:00:05.000 --> 00:00:10.000
  /// sprite.jpg#xywh=160,0,160,90
  /// ```
  List<ThumbnailCue> _parseVtt(String vttContent) {
    final cues = <ThumbnailCue>[];
    final lines = vttContent.split('\n');

    int i = 0;
    while (i < lines.length) {
      final line = lines[i].trim();

      // Skip WEBVTT header and empty lines
      if (line.isEmpty ||
          line.startsWith('WEBVTT') ||
          line.startsWith('NOTE')) {
        i++;
        continue;
      }

      // Look for timestamp line (contains -->)
      if (line.contains('-->')) {
        final parts = line.split('-->');
        if (parts.length != 2) {
          i++;
          continue;
        }

        final startTime = _parseVttTime(parts[0].trim());
        final endTime = _parseVttTime(parts[1].trim());

        // Next line should contain the sprite reference
        i++;
        if (i >= lines.length) break;

        final spriteLine = lines[i].trim();
        if (spriteLine.isEmpty) {
          continue;
        }

        // Parse sprite reference: sprite.jpg#xywh=0,0,160,90
        final cue = _parseSpriteLine(spriteLine, startTime, endTime);
        if (cue != null) {
          cues.add(cue);
        }
      }

      i++;
    }

    return cues;
  }

  /// Parse VTT timestamp to seconds.
  ///
  /// Format: HH:MM:SS.mmm
  double _parseVttTime(String timeStr) {
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

  /// Parse sprite line to extract coordinates.
  ///
  /// Format: sprite.jpg#xywh=0,0,160,90
  ThumbnailCue? _parseSpriteLine(
    String spriteLine,
    double startTime,
    double endTime,
  ) {
    try {
      final hashIndex = spriteLine.indexOf('#xywh=');
      if (hashIndex == -1) return null;

      final spriteFilename = spriteLine.substring(0, hashIndex);
      final coords = spriteLine.substring(hashIndex + 6); // Skip '#xywh='

      final parts = coords.split(',');
      if (parts.length != 4) return null;

      final x = int.parse(parts[0]);
      final y = int.parse(parts[1]);
      final width = int.parse(parts[2]);
      final height = int.parse(parts[3]);

      return ThumbnailCue(
        startTime: startTime,
        endTime: endTime,
        spriteFilename: spriteFilename,
        x: x,
        y: y,
        width: width,
        height: height,
      );
    } catch (e) {
      debugPrint('Error parsing sprite line: $e');
      return null;
    }
  }
}
