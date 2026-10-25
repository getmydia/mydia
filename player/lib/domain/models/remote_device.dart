/// How a paired device is doing. Widgets turn it into text with
/// `AppLocalizations.remoteDeviceStatus`.
enum RemoteDeviceStatus { revoked, neverActive, active, inactive }

/// Domain model for a remote device paired to a user account.
class RemoteDevice {
  final String id;
  final String deviceName;
  final String platform;
  final DateTime? lastSeenAt;
  final bool isRevoked;
  final DateTime createdAt;

  const RemoteDevice({
    required this.id,
    required this.deviceName,
    required this.platform,
    this.lastSeenAt,
    required this.isRevoked,
    required this.createdAt,
  });

  /// Check if this device was recently active (within last 24 hours).
  bool get isRecentlyActive {
    if (lastSeenAt == null) return false;
    final now = DateTime.now();
    final difference = now.difference(lastSeenAt!);
    return difference.inHours < 24;
  }

  /// Where the device stands, for the status label in Settings.
  RemoteDeviceStatus get status {
    if (isRevoked) return RemoteDeviceStatus.revoked;
    if (lastSeenAt == null) return RemoteDeviceStatus.neverActive;
    if (isRecentlyActive) return RemoteDeviceStatus.active;
    return RemoteDeviceStatus.inactive;
  }

  /// Get platform icon name.
  String get platformIcon {
    switch (platform.toLowerCase()) {
      case 'ios':
        return 'phone_iphone';
      case 'android':
        return 'phone_android';
      case 'web':
        return 'language';
      default:
        return 'devices';
    }
  }
}
