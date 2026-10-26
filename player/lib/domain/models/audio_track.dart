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

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AudioTrack && runtimeType == other.runtimeType && id == other.id;

  @override
  int get hashCode => id.hashCode;
}
