import '../sources/files/backend/file_system_backend.dart';
import 'media_probe.dart';
import 'mpv_probe_mapping.dart';

/// Web has no mpv process to probe with.
MediaProbe createPlatformMediaProbe() => const _NoProbe();

class _NoProbe implements MediaProbe {
  const _NoProbe();

  @override
  Future<ProbeResult?> probe(
    PlayableFile playable, {
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      null;
}
