import 'dart:math' as math;

import 'package:flutter/foundation.dart' show kIsWeb;

import '../../domain/models/media_file.dart';
import 'network_info_service.dart';

/// Device category based on screen width.
enum DeviceCategory { mobile, tablet, desktop, widescreen }

/// Context about the current device and network for file selection.
class DeviceContext {
  final DeviceCategory deviceCategory;
  final NetworkType networkType;
  final bool isWeb;

  const DeviceContext({
    required this.deviceCategory,
    required this.networkType,
    required this.isWeb,
  });

  /// Detect the current device context from screen width and network.
  static Future<DeviceContext> detect(double screenWidth) async {
    final category = _categoryFromWidth(screenWidth);
    final network = await getNetworkType();

    return DeviceContext(
      deviceCategory: category,
      networkType: network,
      isWeb: kIsWeb,
    );
  }

  static DeviceCategory _categoryFromWidth(double width) {
    if (width >= 1600) return DeviceCategory.widescreen;
    if (width >= 900) return DeviceCategory.desktop;
    if (width >= 600) return DeviceCategory.tablet;
    return DeviceCategory.mobile;
  }
}

/// Selects the best media file based on device and network context.
class MediaFileSelector {
  /// Parse a resolution string (e.g. "1080p", "4K") to vertical pixel count.
  static int parseToPixels(String? resolution) {
    if (resolution == null) return 0;
    final lower = resolution.toLowerCase().trim();

    // Named resolutions
    if (lower == '4k' || lower == '2160p' || lower == 'uhd') return 2160;
    if (lower == '1440p' || lower == 'qhd' || lower == '2k') return 1440;
    if (lower == '1080p' || lower == 'fhd') return 1080;
    if (lower == '720p' || lower == 'hd') return 720;
    if (lower == '480p' || lower == 'sd') return 480;
    if (lower == '360p') return 360;

    // Try parsing numeric suffix (e.g. "576p")
    final match = RegExp(r'(\d+)p?$').firstMatch(lower);
    if (match != null) return int.parse(match.group(1)!);

    return 0;
  }

  /// Select the best file from [files] given a [context].
  ///
  /// Returns null if [files] is empty.
  static MediaFile? selectBest(List<MediaFile> files, DeviceContext context) {
    if (files.isEmpty) return null;
    if (files.length == 1) return files.first;

    final maxTarget = _maxTargetResolution(context);
    MediaFile? best;
    double bestScore = -1;

    for (final file in files) {
      final score = _score(file, context, maxTarget);
      if (score > bestScore) {
        bestScore = score;
        best = file;
      }
    }

    return best;
  }

  /// Maximum target resolution in vertical pixels for the given context.
  ///
  /// A return value of `0` means "no cap": `_score` treats it as a signal
  /// to skip the target-relative scoring branch and reward raw resolution
  /// directly instead of dividing by a target.
  static int _maxTargetResolution(DeviceContext context) {
    return switch ((context.deviceCategory, context.networkType)) {
      (DeviceCategory.mobile, NetworkType.cellular) => 720,
      (DeviceCategory.mobile, _) => 1080,
      (DeviceCategory.tablet, _) => 1080,
      (DeviceCategory.desktop, _) => 0, // no cap
      (DeviceCategory.widescreen, _) => 0, // no cap
    };
  }

  /// Score a single file. Higher is better.
  static double _score(
    MediaFile file,
    DeviceContext context,
    int maxTarget,
  ) {
    double score = 0;
    final pixels = parseToPixels(file.resolution);

    // Resolution score (0-100): proportional to resolution, penalized if above target
    if (pixels > 0 && maxTarget > 0) {
      if (pixels <= maxTarget) {
        // Proportional: higher resolution = higher score, up to target
        score += (pixels / maxTarget).clamp(0.0, 1.0) * 100;
      } else {
        // Above target: still usable but penalized proportionally
        final overshoot = pixels / maxTarget;
        score += math.max(0, 100 - (overshoot - 1) * 50);
      }
    } else if (pixels > 0) {
      // No cap — just reward higher resolution
      score += (pixels / 2160).clamp(0.0, 1.0) * 100;
    }

    // Direct play bonus (+20)
    if (file.directPlaySupported) {
      score += 20;
    }

    // HDR penalty on web (-15)
    if (context.isWeb && file.hdrFormat != null) {
      score -= 15;
    }

    // Bitrate score (0-10): rewards higher bitrate
    if (file.bitrate != null && file.bitrate! > 0) {
      final bitrateMbps = file.bitrate! / 1000000;
      if (context.networkType == NetworkType.cellular && bitrateMbps > 10) {
        // Penalize very high bitrate on cellular
        score -= (bitrateMbps - 10) * 2;
      } else {
        // Reward higher bitrate up to 10 points
        score += (bitrateMbps / 5).clamp(0.0, 1.0) * 10;
      }
    }

    return score;
  }
}
