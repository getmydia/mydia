import '../settings/settings_service.dart';
import 'update_track.dart';

/// Reads and writes the chosen release track.
///
/// A thin seam over SettingsService so the backends can take a track source
/// without depending on the whole settings surface, and so a test can hand
/// them a stub without a keychain.
class UpdateTrackStore {
  UpdateTrackStore({SettingsService? settings})
      : _settings = settings ?? SettingsService();

  final SettingsService _settings;

  /// The stored track, or stable. An unreadable or unrecognised value falls
  /// back rather than throwing: a broken preference must not stop the app
  /// from offering updates at all.
  Future<UpdateTrack> read() async {
    try {
      return UpdateTrack.fromWireName(await _settings.getUpdateTrack()) ??
          UpdateTrack.stable;
    } catch (_) {
      return UpdateTrack.stable;
    }
  }

  Future<void> write(UpdateTrack track) async {
    await _settings.setUpdateTrack(track.wireName);
  }
}
