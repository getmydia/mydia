import 'system_media_session.dart';

Future<SystemMediaSession> createPlatformMediaSession({
  required Duration Function() position,
}) async =>
    NoopMediaSession();
