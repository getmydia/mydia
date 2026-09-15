# Audio-language vocabulary for release titles, loaded at compile time by
# Mydia.Indexers.ReleaseLanguages.
#
# Patterns are Erlang :re sources compiled with :caseless and :unicode. The
# loader wraps every pattern in alphanumeric boundaries, so "DUAL" matches
# ".DUAL." but not "-DUALiTY", and "ITA" does not match inside "ITALIAN".
# Do not add \b or (?i) yourself.
#
# :original in a languages list means the item's original language.

%{
  # Removed before any token is matched. Each names subtitles, never audio, and
  # several would otherwise trip an audio token ("Multi-Subs" contains MULTI,
  # "Eng Subs" contains ENG).
  subtitle_markers: [
    "(?:eng(?:lish)?|multi|m|e)[ ._-]?subs?",
    "vostfr",
    "subfrench",
    "subbed",
    "hardsubs?",
    "softsubs?"
  ],
  tokens: [
    %{patterns: ["dual[ ._-]?audio", "dual"], languages: [:original, "en"]},
    %{patterns: ["multi[ ._-]?audio", "multi"], languages: [:original]},
    # Bare "Dubbed" is deliberately absent: "Hindi Dubbed" names a Hindi dub.
    %{patterns: ["eng(?:lish)?[ ._-]?dub(?:bed)?", "english", "eng"], languages: ["en"]},
    %{patterns: ["japanese", "jpn"], languages: ["ja"]},
    %{patterns: ["italian", "ita"], languages: ["it"]},
    %{patterns: ["spanish", "latino", "castellano", "esp"], languages: ["es"]},
    %{patterns: ["truefrench", "french", "vff", "vfq", "vf2", "vfi"], languages: ["fr"]},
    %{patterns: ["german"], languages: ["de"]},
    %{patterns: ["russian", "rus"], languages: ["ru"]},
    %{patterns: ["korean", "kor"], languages: ["ko"]},
    %{patterns: ["chinese", "chi"], languages: ["zh"]},
    %{patterns: ["hindi"], languages: ["hi"]},
    %{patterns: ["portuguese", "por"], languages: ["pt"]}
  ]
}
