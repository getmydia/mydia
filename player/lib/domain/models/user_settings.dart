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

  const UserSettings({
    required this.serverUrl,
    required this.username,
    this.defaultQuality = 'auto',
    this.autoSkipSegments = false,
  });

  UserSettings copyWith({
    String? serverUrl,
    String? username,
    String? defaultQuality,
    bool? autoSkipSegments,
  }) {
    return UserSettings(
      serverUrl: serverUrl ?? this.serverUrl,
      username: username ?? this.username,
      defaultQuality: defaultQuality ?? this.defaultQuality,
      autoSkipSegments: autoSkipSegments ?? this.autoSkipSegments,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'serverUrl': serverUrl,
      'username': username,
      'defaultQuality': defaultQuality,
      'autoSkipSegments': autoSkipSegments,
    };
  }

  factory UserSettings.fromJson(Map<String, dynamic> json) {
    return UserSettings(
      serverUrl: json['serverUrl'] as String? ?? '',
      username: json['username'] as String? ?? '',
      defaultQuality: json['defaultQuality'] as String? ?? 'auto',
      autoSkipSegments: json['autoSkipSegments'] as bool? ?? false,
    );
  }
}
