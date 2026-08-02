import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/colors.dart';
import '../../domain/models/media_file.dart';

/// Badge type for displaying quality information
enum QualityBadgeType {
  resolution,
  hdr,
  codec,
}

/// A small, pill-shaped badge displaying quality information
class QualityBadge extends StatelessWidget {
  final String label;
  final QualityBadgeType type;

  const QualityBadge({
    super.key,
    required this.label,
    required this.type,
  });

  /// Creates a resolution badge (e.g., "4K", "1080p")
  const QualityBadge.resolution(this.label, {super.key})
      : type = QualityBadgeType.resolution;

  /// Creates an HDR badge (e.g., "HDR10", "Dolby Vision")
  const QualityBadge.hdr(this.label, {super.key}) : type = QualityBadgeType.hdr;

  /// Creates a codec badge (e.g., "HEVC", "H.264")
  const QualityBadge.codec(this.label, {super.key})
      : type = QualityBadgeType.codec;

  // Badge type no longer selects a hue. The palette has a single accent and it
  // is reserved for actions and state (play, active nav, scrubber, focus);
  // badges are information, so they read as neutral chips. The enum stays
  // because callers use it and it may carry non-colour differences later.
  Color get _backgroundColor => AppColors.surfaceVariant;

  Color get _textColor => AppColors.textPrimary;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _backgroundColor,
        borderRadius: BorderRadius.circular(AppTheme.radiusBadge),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: _textColor,
          height: 1.0,
        ),
      ),
    );
  }
}

/// A row of quality badges with appropriate spacing
class QualityBadgeRow extends StatelessWidget {
  final List<QualityBadge> badges;
  final double spacing;

  const QualityBadgeRow({
    super.key,
    required this.badges,
    this.spacing = 6.0,
  });

  @override
  Widget build(BuildContext context) {
    if (badges.isEmpty) {
      return const SizedBox.shrink();
    }

    return Wrap(
      spacing: spacing,
      runSpacing: spacing,
      children: badges,
    );
  }
}

/// Quality information extracted from a MediaFile
class MediaQuality {
  final String? resolution;
  final String? hdrFormat;
  final String? codec;

  const MediaQuality({
    this.resolution,
    this.hdrFormat,
    this.codec,
  });

  /// Returns true if any quality information is present
  bool get hasQuality =>
      resolution != null || hdrFormat != null || codec != null;

  /// Converts quality information to a list of badges
  List<QualityBadge> toBadges() {
    final badges = <QualityBadge>[];

    if (resolution != null) {
      badges.add(QualityBadge.resolution(resolution!));
    }

    if (hdrFormat != null) {
      badges.add(QualityBadge.hdr(hdrFormat!));
    }

    if (codec != null) {
      badges.add(QualityBadge.codec(codec!));
    }

    return badges;
  }
}

/// Helper function to extract the best quality from a list of MediaFiles
///
/// Returns the quality information from the file with:
/// 1. Highest resolution (4K > 1080p > 720p, etc.)
/// 2. HDR format if available
/// 3. Best codec if available
MediaQuality getBestQuality(List<MediaFile> files) {
  if (files.isEmpty) {
    return const MediaQuality();
  }

  // Sort by resolution priority (higher is better)
  final sortedFiles = List<MediaFile>.from(files)
    ..sort((a, b) {
      final resA = _getResolutionPriority(a.resolution);
      final resB = _getResolutionPriority(b.resolution);
      return resB.compareTo(resA); // Descending order
    });

  final bestFile = sortedFiles.first;

  return MediaQuality(
    resolution: bestFile.resolution,
    hdrFormat: bestFile.hdrFormat,
    codec: bestFile.codec,
  );
}

/// Returns a priority value for resolution sorting
/// Higher values = better quality
int _getResolutionPriority(String? resolution) {
  if (resolution == null) return 0;

  final res = resolution.toLowerCase();

  // 8K variants
  if (res.contains('8k') || res.contains('4320')) return 800;

  // 4K/UHD variants
  if (res.contains('4k') || res.contains('2160') || res.contains('uhd')) {
    return 400;
  }

  // 1440p/QHD variants
  if (res.contains('1440') || res.contains('qhd')) return 300;

  // 1080p/FHD variants
  if (res.contains('1080') || res.contains('fhd')) return 200;

  // 720p/HD variants
  if (res.contains('720') || res.contains('hd')) return 100;

  // 480p/SD variants
  if (res.contains('480') || res.contains('sd')) return 50;

  // Unknown resolution - lower priority
  return 10;
}
