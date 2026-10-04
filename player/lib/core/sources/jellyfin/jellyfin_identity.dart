/// How this install introduces itself to Jellyfin. The device id is per
/// install and stable across launches; Jellyfin ties sessions and Quick
/// Connect requests to it.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../../auth/auth_storage.dart';
import '../plex/plex_identity.dart';

@immutable
class JellyfinIdentity {
  const JellyfinIdentity({
    required this.deviceId,
    required this.version,
    required this.deviceName,
    this.client = 'Mydia Player',
  });

  static const deviceIdKey = 'jellyfin/device_id';

  final String deviceId;
  final String version;
  final String deviceName;
  final String client;

  /// The `Authorization` header value. Without [token] it is what the
  /// sign-in endpoints expect.
  String authorization([String? token]) {
    // A double quote would end the field early.
    String q(String v) => v.replaceAll('"', "'");
    final base = 'MediaBrowser Client="${q(client)}", '
        'Device="${q(deviceName)}", DeviceId="${q(deviceId)}", '
        'Version="${q(version)}"';
    return token == null || token.isEmpty ? base : '$base, Token="$token"';
  }

  static Future<String> loadDeviceId(AuthStorage storage) async {
    final existing = await storage.read(deviceIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final created = const Uuid().v4().replaceAll('-', '');
    await storage.write(deviceIdKey, created);
    return created;
  }
}

final jellyfinIdentityProvider = FutureProvider<JellyfinIdentity>((ref) async {
  final id = await JellyfinIdentity.loadDeviceId(getAuthStorage());
  String version;
  try {
    version = (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    version = '0';
  }
  return JellyfinIdentity(
    deviceId: id,
    version: version,
    deviceName:
        'Mydia Player on ${PlexIdentity.platformName(defaultTargetPlatform)}',
  );
});
