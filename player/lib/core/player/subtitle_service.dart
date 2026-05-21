import 'package:http/http.dart' as http;
import 'dart:convert';
import '../../domain/models/subtitle_track.dart';
import 'package:flutter/foundation.dart';

/// Service for fetching subtitle tracks from the Mydia API.
class SubtitleService {
  final String serverUrl;
  final String authToken;

  const SubtitleService({
    required this.serverUrl,
    required this.authToken,
  });

  /// Fetch available subtitle tracks for a media item.
  ///
  /// Parameters:
  ///   - mediaId: The ID of the media item (movie, episode, or file)
  ///   - mediaType: Type of media ('movie', 'episode', or 'file')
  ///
  /// Returns a list of available subtitle tracks.
  Future<List<SubtitleTrack>> fetchSubtitles(
    String mediaId,
    String mediaType,
  ) async {
    try {
      final url = '$serverUrl/api/player/v1/subtitles/$mediaType/$mediaId';
      debugPrint('Fetching subtitles from: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $authToken',
          'Accept': 'application/json',
        },
      );

      if (response.statusCode == 200) {
        final jsonData = json.decode(response.body) as Map<String, dynamic>;
        final tracks = (jsonData['data'] as List<dynamic>)
            .map((track) =>
                SubtitleTrack.fromJson(track as Map<String, dynamic>))
            .toList();

        debugPrint('Found ${tracks.length} subtitle tracks');
        return tracks;
      } else if (response.statusCode == 404) {
        debugPrint('No subtitles found for $mediaType:$mediaId');
        return [];
      } else {
        debugPrint('Failed to fetch subtitles: ${response.statusCode}');
        throw Exception('Failed to fetch subtitles: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error fetching subtitles: $e');
      rethrow;
    }
  }

  /// Build the URL for downloading a specific subtitle track.
  ///
  /// Parameters:
  ///   - mediaId: The ID of the media item
  ///   - mediaType: Type of media ('movie', 'episode', or 'file')
  ///   - trackId: The track identifier
  ///   - format: Desired format (srt, vtt, ass) - defaults to 'vtt' for web compatibility
  ///
  /// Returns the full URL for downloading the subtitle.
  String buildSubtitleUrl(
    String mediaId,
    String mediaType,
    String trackId, {
    String format = 'vtt',
  }) {
    return '$serverUrl/api/player/v1/subtitles/$mediaType/$mediaId/$trackId?format=$format';
  }

  /// Download subtitle content as a string.
  ///
  /// This is useful for external subtitle files that need to be loaded
  /// into the video player.
  Future<String> downloadSubtitleContent(
    String mediaId,
    String mediaType,
    String trackId, {
    String format = 'vtt',
  }) async {
    try {
      final url = buildSubtitleUrl(mediaId, mediaType, trackId, format: format);
      debugPrint('Downloading subtitle from: $url');

      final response = await http.get(
        Uri.parse(url),
        headers: {
          'Authorization': 'Bearer $authToken',
        },
      );

      if (response.statusCode == 200) {
        return response.body;
      } else {
        throw Exception('Failed to download subtitle: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('Error downloading subtitle: $e');
      rethrow;
    }
  }
}
