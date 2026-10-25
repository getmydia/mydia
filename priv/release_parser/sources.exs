alias Mydia.Library.ReleaseParser.VocabularyEntry

# Source / quality tags. WEB carries a heavy title-zone penalty so the
# Madame Web / Black Phone 2 case ("Madame.Web.2024.1080p") doesn't pick
# up `Web` as a source — V1 → V2 carve-out, now data-driven.
#
# Note: WEB-DL and WEBRip are pre-split by the tokenizer's compound-dash
# allow-list (WEB-DL → ["WEB", "DL"]), so the WEB entry covers all WEB-*
# variants once the dash is gone. WEBRip is a single token and needs its
# own entry.

[
  %VocabularyEntry{
    label: :source,
    aliases: ["REMUX"],
    canonical: "REMUX",
    confidence: 0.95,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["BluRay", "BLURAY", "BD"],
    canonical: "BluRay",
    confidence: 0.95,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :source,
    aliases: ["BDRip"],
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
    aliases: ["WEB"],
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
    aliases: ["DVDScr"],
    canonical: "DVDScr",
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
    aliases: ["DVD"],
    canonical: "DVD",
    confidence: 0.8,
    title_zone_bonus: -0.4,
    metadata_zone_bonus: 0.05
  }
]
