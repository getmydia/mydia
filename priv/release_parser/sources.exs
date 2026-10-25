alias Mydia.Library.ReleaseParser.VocabularyEntry

# Source / quality tags. WEB carries a heavy title-zone penalty so the
# Madame Web / Black Phone 2 case ("Madame.Web.2024.1080p") doesn't pick
# up `Web` as a source — V1 → V2 carve-out, now data-driven.
#
# Note: WEB-DL and WEBRip are pre-split by the tokenizer's compound-dash
# allow-list (WEB-DL → ["WEB", "DL"]), so the WEB entry covers all WEB-*
# variants once the dash is gone. WEBRip is a single token and needs its
# own entry. `Blu-ray` is not on that list, so it arrives whole.

[
  %VocabularyEntry{
    label: :source,
    aliases: ["REMUX", "BDRemux", "UHDRemux"],
    canonical: "REMUX",
    confidence: 0.95,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["BluRay", "BLURAY", "Blu-ray", "BD", "MBluRay", "UHDBD"],
    canonical: "BluRay",
    confidence: 0.95,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["BDRip", "UHDBDRip"],
    canonical: "BluRay",
    confidence: 0.9,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["BRRip"],
    canonical: "BluRay",
    confidence: 0.9,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["WEBRip"],
    canonical: "WEBRip",
    confidence: 0.9,
    title_zone_bonus: -0.3,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["WEB", "WEBDL"],
    canonical: "WEB",
    confidence: 0.85,
    title_zone_bonus: -0.7,
    metadata_zone_bonus: 0.2
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["HDTV"],
    canonical: "HDTV",
    confidence: 0.9,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["PDTV"],
    canonical: "PDTV",
    confidence: 0.9,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["SDTV"],
    canonical: "SDTV",
    confidence: 0.9,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["DVDRip"],
    canonical: "DVDRip",
    confidence: 0.9,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["DVD", "DVDR", "DVD-R", "MDVDR", "DVD5", "DVD9"],
    canonical: "DVD",
    confidence: 0.8,
    title_zone_bonus: -0.4,
    metadata_zone_bonus: 0.05
  },

  # Cam-tier sources (camcorder and pre-release captures). Their metadata
  # confidence stays below every good source above, DVD included, so an
  # explicit good token wins the :source singleton, matching
  # `Mydia.Quality.Sources`. `Screener` and `Workprint` are also title words,
  # so these take WEB's title-zone penalty too. The tokenizer keeps dashed
  # forms whole, so `HD-TS` needs its own alias.
  %VocabularyEntry{
    label: :source,
    aliases: ["HDCAM", "HD-CAM", "CAMRip", "CAM-Rip", "HQCAM"],
    canonical: "CAM",
    confidence: 0.75,
    title_zone_bonus: -0.7,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["Telesync", "HDTS", "HD-TS", "PDVD", "PreDVD"],
    canonical: "Telesync",
    confidence: 0.75,
    title_zone_bonus: -0.7,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["Telecine", "HDTC", "HD-TC"],
    canonical: "Telecine",
    confidence: 0.75,
    title_zone_bonus: -0.7,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["DVDScr", "BDScr", "WEBScr", "Screener", "DVDScreener", "BDScreener"],
    canonical: "Screener",
    confidence: 0.75,
    title_zone_bonus: -0.7,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["Workprint"],
    canonical: "Workprint",
    confidence: 0.75,
    title_zone_bonus: -0.7,
    metadata_zone_bonus: 0.05
  },

  # Scene abbreviations. As whole tokens they are already delimited by a
  # dot, space or bracket on both sides; the trailing `-TS` group position
  # is excluded by the release-group pre-pass in `ReleaseParser`. They are
  # also ordinary words (`Cam`, `Ts`), and the title-zone penalty drops them
  # below the resolver's vocabulary floor there.
  %VocabularyEntry{
    label: :source,
    aliases: ["CAM"],
    canonical: "CAM",
    confidence: 0.7,
    title_zone_bonus: -0.7,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["TS"],
    canonical: "Telesync",
    confidence: 0.7,
    title_zone_bonus: -0.7,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["TC"],
    canonical: "Telecine",
    confidence: 0.7,
    title_zone_bonus: -0.7,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["SCR"],
    canonical: "Screener",
    confidence: 0.7,
    title_zone_bonus: -0.7,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["WP"],
    canonical: "Workprint",
    confidence: 0.7,
    title_zone_bonus: -0.7,
    metadata_zone_bonus: 0.05
  }
]
