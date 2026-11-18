/// User settings model representing app preferences.
class UserSettings {
  final String serverUrl;
  final String username;
  final String defaultQuality;

  /// Whether detected intros and credits are skipped without asking.
  ///
  /// Off by default. Each segment is still skipped at most once per playback,
  /// so seeking back into an intro on purpose keeps working.
  final bool autoSkipSegments;

  /// Whether commercial breaks are skipped without asking.
  ///
  /// On by default. Like intros, each break is skipped at most once per
  /// playback.
  final bool autoSkipCommercials;

  const UserSettings({
    required this.serverUrl,
    required this.username,
    this.defaultQuality = 'auto',
    this.autoSkipSegments = false,
    this.autoSkipCommercials = true,
  });

  UserSettings copyWith({
    String? serverUrl,
    String? username,
    String? defaultQuality,
    bool? autoSkipSegments,
    bool? autoSkipCommercials,
  }) {
    return UserSettings(
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      autoSkipSegments: autoSkipSegments ?? this.autoSkipSegments,
      autoSkipCommercials: autoSkipCommercials ?? this.autoSkipCommercials,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'serverUrl': serverUrl,
      'username': username,
      'defaultQuality': defaultQuality,
      'autoSkipSegments': autoSkipSegments,
      'autoSkipCommercials': autoSkipCommercials,
    };
  }

  factory UserSettings.fromJson(Map<String, dynamic> json) {
    return UserSettings(
      serverUrl: json['serverUrl'] as String? ?? '',
      username: json['username'] as String? ?? '',
      defaultQuality: json['defaultQuality'] as String? ?? 'auto',
      autoSkipSegments: json['autoSkipSegments'] as bool? ?? false,
      autoSkipCommercials: json['autoSkipCommercials'] as bool? ?? true,
    );
  }
}
