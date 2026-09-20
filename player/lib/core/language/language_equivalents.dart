/// ISO 639 equivalence, ported from `Mydia.Metadata.LanguageCode`.
///
/// The player and the server both decide "is this the same language" about the
/// same file: the server in `SubtitlePreferences.operator_default/1` through
/// `LanguageCode.matches?/2`, the player when matching a stored preference
/// against a track list. The preference itself is stored server-side, so two
/// tables of different sizes are two answers to one question.
///
/// ISO 639-1 keys to their 639-2 forms. Where /T and /B differ both are
/// listed, /T first. Matroska and ffprobe overwhelmingly write /B, so omitting
/// those would leave German and French tracks unmatchable.
///
/// **Kept in step by `test/mydia/metadata/language_code_parity_test.exs`**,
/// which reads this file and compares it against the Elixir table. Add a
/// language to one side and the Elixir suite fails.
library;

const Map<String, List<String>> kLanguageEquivalents = {
  'af': ['afr'],
  'am': ['amh'],
  'ar': ['ara'],
  'az': ['aze'],
  'be': ['bel'],
  'bg': ['bul'],
  'bn': ['ben'],
  'bs': ['bos'],
  'ca': ['cat'],
  'cs': ['ces', 'cze'],
  'cy': ['cym', 'wel'],
  'da': ['dan'],
  'de': ['deu', 'ger'],
  'el': ['ell', 'gre'],
  'en': ['eng'],
  'eo': ['epo'],
  'es': ['spa'],
  'et': ['est'],
  'eu': ['eus', 'baq'],
  'fa': ['fas', 'per'],
  'fi': ['fin'],
  'fr': ['fra', 'fre'],
  'ga': ['gle'],
  'gl': ['glg'],
  'gu': ['guj'],
  'ha': ['hau'],
  'he': ['heb'],
  'hi': ['hin'],
  'hr': ['hrv'],
  'hu': ['hun'],
  'hy': ['hye', 'arm'],
  'id': ['ind'],
  'ig': ['ibo'],
  'is': ['isl', 'ice'],
  'it': ['ita'],
  'ja': ['jpn'],
  'ka': ['kat', 'geo'],
  'kk': ['kaz'],
  'km': ['khm'],
  'kn': ['kan'],
  'ko': ['kor'],
  'la': ['lat'],
  'lo': ['lao'],
  'lt': ['lit'],
  'lv': ['lav'],
  'mi': ['mri', 'mao'],
  'mk': ['mkd', 'mac'],
  'ml': ['mal'],
  'mn': ['mon'],
  'mr': ['mar'],
  'ms': ['msa', 'may'],
  'my': ['mya', 'bur'],
  'ne': ['nep'],
  'nl': ['nld', 'dut'],
  'no': ['nor'],
  'pa': ['pan'],
  'pl': ['pol'],
  'pt': ['por'],
  'ro': ['ron', 'rum'],
  'ru': ['rus'],
  'si': ['sin'],
  'sk': ['slk', 'slo'],
  'sl': ['slv'],
  'sq': ['sqi', 'alb'],
  'sr': ['srp'],
  'sv': ['swe'],
  'sw': ['swa'],
  'ta': ['tam'],
  'te': ['tel'],
  'th': ['tha'],
  'tl': ['tgl'],
  'tr': ['tur'],
  'uk': ['ukr'],
  'ur': ['urd'],
  'uz': ['uzb'],
  'vi': ['vie'],
  'xh': ['xho'],
  'yi': ['yid'],
  'yo': ['yor'],
  'zh': ['zho', 'chi'],
  'zu': ['zul'],
};

/// Reverse index, so a three-letter tag resolves to its two-letter form
/// without scanning the map on every comparison. The Elixir side builds the
/// same index at compile time from the same map.
final Map<String, String> _threeToTwo = {
  for (final entry in kLanguageEquivalents.entries)
    for (final three in entry.value) three: entry.key,
};

/// The single code a language is compared by: its ISO 639-1 form when the
/// table knows it, the lowercased primary subtag when it does not, and the
/// empty string for a blank or undetermined tag.
///
/// `und` is ffprobe's explicit "undetermined" and a bare empty string is what
/// an untagged track yields. Neither names a language, so both collapse to the
/// empty string and [subtitlePreferenceLanguageEquals] refuses them.
String canonicalLanguage(String code) {
  final primary = code.trim().toLowerCase().split(RegExp('[-_]')).first;
  if (primary.isEmpty || primary == 'und') return '';
  if (kLanguageEquivalents.containsKey(primary)) return primary;
  return _threeToTwo[primary] ?? primary;
}

/// Whether two language tags name the same language.
///
/// Deliberately not `subtitleLanguagesCompatible` from
/// `subtitle_track_builder.dart`. That one treats `und` and an empty tag as
/// compatible with anything, which is right when carrying a known track across
/// a quality switch and wrong here: it would attach an untagged track to any
/// preference at all.
bool subtitlePreferenceLanguageEquals(String a, String b) {
  final left = canonicalLanguage(a);
  final right = canonicalLanguage(b);
  if (left.isEmpty || right.isEmpty) return false;
  return left == right;
}
