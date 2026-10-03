/// How this install introduces itself to Plex. The client identifier is
/// per install, stable across launches, and shared by every Plex account.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:uuid/uuid.dart';

import '../../auth/auth_storage.dart';

@immutable
class PlexIdentity {
  const PlexIdentity({
    required this.clientIdentifier,
    required this.version,
    required this.platform,
    this.product = 'Mydia Player',
    this.deviceName = 'Mydia Player',
  });

  static const clientIdKey = 'plex/client_identifier';

  final String clientIdentifier;
  final String version;
  final String platform;
  final String product;
  final String deviceName;

  Map<String, String> get headers => {
        'X-Plex-Product': product,
        'X-Plex-Version': version,
        'X-Plex-Client-Identifier': clientIdentifier,
        'X-Plex-Platform': platform,
        'X-Plex-Device-Name': deviceName,
        'Accept': 'application/json',
      };

  static String platformName(TargetPlatform platform) => switch (platform) {
        TargetPlatform.android => 'Android',
        TargetPlatform.iOS => 'iOS',
        TargetPlatform.macOS => 'macOS',
        TargetPlatform.windows => 'Windows',
        TargetPlatform.linux || TargetPlatform.fuchsia => 'Linux',
      };

  static Future<String> loadClientIdentifier(AuthStorage storage) async {
    final existing = await storage.read(clientIdKey);
    if (existing != null && existing.isNotEmpty) return existing;
    final created = const Uuid().v4().replaceAll('-', '');
    await storage.write(clientIdKey, created);
    return created;
  }
}

final plexIdentityProvider = FutureProvider<PlexIdentity>((ref) async {
  final id = await PlexIdentity.loadClientIdentifier(getAuthStorage());
  String version;
  try {
    version = (await PackageInfo.fromPlatform()).version;
  } catch (_) {
    version = '0';
  }
  return PlexIdentity(
    clientIdentifier: id,
    version: version,
    platform: PlexIdentity.platformName(defaultTargetPlatform),
  );
});
