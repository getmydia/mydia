/// Represents an audio track available in a media file.
class AudioTrack {
  /// Unique identifier for the track
  final String id;

  /// ISO 639-2 language code (e.g., 'eng', 'spa')
  final String language;

  /// Human-readable title (optional)
  final String? title;

  /// Whether this is the default track
  final bool isDefault;

  const AudioTrack({
    required this.id,
    required this.language,
    this.title,
    this.isDefault = false,
  });

  /// Returns a display name for the track
  String get displayName {
    if (title != null && title!.isNotEmpty) {
      return title!;
    }
    return _languageCodeToName(language);
  }

  /// Convert language code to human-readable name
  static String _languageCodeToName(String code) {
    const languageMap = {
      'eng': 'English',
      'spa': 'Spanish',
      'fre': 'French',
      'ger': 'German',
      'ita': 'Italian',
      'por': 'Portuguese',
      'rus': 'Russian',
      'jpn': 'Japanese',
      'kor': 'Korean',
      'chi': 'Chinese',
      'ara': 'Arabic',
      'hin': 'Hindi',
    };
    return languageMap[code] ?? code.toUpperCase();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioTrack && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
