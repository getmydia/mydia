import 'package:dbus/dbus.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../player/platform_features.dart';
import 'mpris_media_session.dart';
import 'system_media_session.dart';

/// MPRIS on Linux; nothing elsewhere until PR 2.
Future<SystemMediaSession> createPlatformMediaSession({
  required Duration Function() position,
}) async {
  if (!PlatformFeatures.isLinux) return NoopMediaSession();
  DBusClient? client;
  try {
    client = DBusClient.session();
    final session =
        await MprisMediaSession.connect(client: client, position: position);
    if (session != null) return session;
  } catch (e) {
    debugPrint('[MediaSession] no session bus: $e');
  }
  try {
    await client?.close();
  } catch (_) {}
  return NoopMediaSession();
}
