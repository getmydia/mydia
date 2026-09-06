import 'dart:io';

/// What the running process can learn about its own Flatpak installation.
///
/// Detection is the existence of /.flatpak-info rather than the FLATPAK_ID
/// environment variable, because the file survives an environment a launcher
/// or a wrapper script has scrubbed.
class FlatpakEnvironment {
  const FlatpakEnvironment({this.infoPath = '/.flatpak-info'});

  /// Injectable for tests. Production always reads the real path.
  final String infoPath;

  /// Existence, not parseability. If a future runtime changes the file's
  /// format and [appId] or [branch] come back null, this must still be true:
  /// the sandbox is real regardless of whether this parser understands it.
  /// Falling back to `appId != null` here would route a Flatpak install back
  /// to LinuxUpdater the moment the format drifted, which is the exact
  /// failure this whole plan exists to remove.
  bool get isFlatpak => File(infoPath).existsSync();

  /// The Flatpak application id, for example dev.mydia.player.
  String? get appId => _value(section: 'Application', key: 'name');

  /// The installed branch, which is the release channel: stable or beta.
  String? get branch => _value(section: 'Instance', key: 'branch');

  String? _value({required String section, required String key}) {
    final file = File(infoPath);
    if (!file.existsSync()) return null;

    String? current;
    for (final raw in file.readAsLinesSync()) {
      final line = raw.trim();
      if (line.startsWith('[') && line.endsWith(']')) {
        current = line.substring(1, line.length - 1);
        continue;
      }
      if (current != section) continue;

      final split = line.indexOf('=');
      if (split <= 0) continue;
      if (line.substring(0, split) == key) return line.substring(split + 1);
    }
    return null;
  }
}
