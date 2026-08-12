/// A subtitle offered by a provider, not yet downloaded.
class SubtitleCandidate {
  /// Opaque signed handle. Pass back to downloadSubtitle. Valid 15 minutes.
  final String token;

  /// ISO 639-1 language code.
  final String language;

  /// The provider's file name, usually naming the release it matches.
  final String? releaseName;

  final String format;
  final double? rating;
  final int? downloadCount;
  final bool hearingImpaired;

  /// The provider matched this by media file hash, the strongest signal.
  final bool hashMatch;

  final int score;
  final String providerName;

  const SubtitleCandidate({
    required this.token,
    required this.language,
    this.releaseName,
    required this.format,
    this.rating,
    this.downloadCount,
    required this.hearingImpaired,
    required this.hashMatch,
    required this.score,
    required this.providerName,
  });

  String get displayLanguage =>
      _languageNames[language] ?? language.toUpperCase();

  static const _languageNames = {
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'de': 'German',
    'it': 'Italian',
    'pt': 'Portuguese',
    'ru': 'Russian',
    'ja': 'Japanese',
    'ko': 'Korean',
    'zh': 'Chinese',
    'ar': 'Arabic',
    'hi': 'Hindi',
    'nl': 'Dutch',
    'pl': 'Polish',
    'sv': 'Swedish',
    'tr': 'Turkish',
  };

  /// Maps an ISO 639-2 code, as reported for embedded tracks, to ISO 639-1,
  /// which is what provider search expects.
  static String? toIso6391(String code) {
    if (code.length == 2) return code;
    return const {
      'eng': 'en',
      'spa': 'es',
      'fra': 'fr',
      'fre': 'fr',
      'deu': 'de',
      'ger': 'de',
      'ita': 'it',
      'por': 'pt',
      'rus': 'ru',
      'jpn': 'ja',
      'kor': 'ko',
      'chi': 'zh',
      'zho': 'zh',
      'ara': 'ar',
      'hin': 'hi',
      'nld': 'nl',
      'dut': 'nl',
      'pol': 'pl',
      'swe': 'sv',
      'tur': 'tr',
    }[code];
  }
}

/// The outcome of consulting one provider during a search.
class SubtitleProviderStatus {
  final String name;
  final int? quotaRemaining;
  final int? quotaTotal;
  final String? error;

  const SubtitleProviderStatus({
    required this.name,
    this.quotaRemaining,
    this.quotaTotal,
    this.error,
  });

  bool get failed => error != null;

  String? get quotaLabel {
    final remaining = quotaRemaining;
    final total = quotaTotal;
    if (remaining == null || total == null) return null;
    return '$remaining of $total left today';
  }
}
