/// Storage settings for download quota management.
///
/// Allows users to configure maximum storage limits and automatic cleanup.
library;

import 'package:hive_ce/hive.dart';

part 'storage_settings.g.dart';

/// Cleanup policy for automatic storage management.
enum CleanupPolicy {
  /// Clean up oldest downloads first (by download date)
  byDate,

  /// Clean up least recently used downloads first
  lru;

  String get display {
    switch (this) {
      case CleanupPolicy.byDate:
        return 'Oldest First';
      case CleanupPolicy.lru:
        return 'Least Recently Used';
    }
  }
}

/// Storage settings configuration.
@HiveType(typeId: 2)
class StorageSettings {
  /// Maximum storage limit in bytes. Null means no limit.
  @HiveField(0)
  final int? maxStorageBytes;

  /// Warning threshold as a percentage (0.0 to 1.0).
  /// Warning is shown when usage exceeds this threshold.
  @HiveField(1)
  final double warningThreshold;

  /// Whether automatic cleanup is enabled.
  @HiveField(2)
  final bool autoCleanupEnabled;

  /// The cleanup policy to use when auto-cleanup is enabled.
  @HiveField(3)
  final String cleanupPolicyValue;

  const StorageSettings({
    this.maxStorageBytes,
    this.warningThreshold = 0.9,
    this.autoCleanupEnabled = false,
    this.cleanupPolicyValue = 'byDate',
  });

  /// Default storage settings with no limit.
  static const StorageSettings defaultSettings = StorageSettings();

  /// Default storage limit presets in bytes.
  static const int gb1 = 1024 * 1024 * 1024;
  static const int gb2 = 2 * 1024 * 1024 * 1024;
  static const int gb5 = 5 * 1024 * 1024 * 1024;
  static const int gb10 = 10 * 1024 * 1024 * 1024;
  static const int gb20 = 20 * 1024 * 1024 * 1024;

  /// Get the cleanup policy enum value.
  CleanupPolicy get cleanupPolicy {
    return cleanupPolicyValue == 'lru'
        ? CleanupPolicy.lru
        : CleanupPolicy.byDate;
  }

  /// Check if storage limit is set.
  bool get hasLimit => maxStorageBytes != null && maxStorageBytes! > 0;

  /// Calculate current usage percentage.
  double usagePercentage(int currentUsage) {
    if (!hasLimit) return 0.0;
    return (currentUsage / maxStorageBytes!).clamp(0.0, 1.0);
  }

  /// Check if warning threshold is exceeded.
  bool isWarningThresholdExceeded(int currentUsage) {
    if (!hasLimit) return false;
    return usagePercentage(currentUsage) >= warningThreshold;
  }

  /// Check if storage is full (at 100% of limit).
  bool isStorageFull(int currentUsage) {
    if (!hasLimit) return false;
    return currentUsage >= maxStorageBytes!;
  }

  /// Get remaining storage in bytes.
  int remainingBytes(int currentUsage) {
    if (!hasLimit) return -1; // -1 indicates unlimited
    return (maxStorageBytes! - currentUsage).clamp(0, maxStorageBytes!);
  }

  StorageSettings copyWith({
    int? maxStorageBytes,
    double? warningThreshold,
    bool? autoCleanupEnabled,
    CleanupPolicy? cleanupPolicy,
    bool clearMaxStorageLimit = false,
  }) {
    return StorageSettings(
      maxStorageBytes: clearMaxStorageLimit
          ? null
          : (maxStorageBytes ?? this.maxStorageBytes),
      warningThreshold: warningThreshold ?? this.warningThreshold,
      autoCleanupEnabled: autoCleanupEnabled ?? this.autoCleanupEnabled,
      cleanupPolicyValue: cleanupPolicy?.name ?? cleanupPolicyValue,
    );
  }

  /// Format storage size for display.
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
