alias Mydia.Library.ReleaseParser.VocabularyEntry

# HDR formats. "DV" and "DoVi" are short tokens that can collide with
# title content, so they carry a stronger title-zone penalty than
# spelled-out variants. "Dolby Vision" with a space becomes two tokens
# ("Dolby", "Vision") after the tokenizer, and "HDR10.PLUS" becomes
# "HDR10" and "PLUS". Neither second word is in this vocab on its own:
# QualityExtractor.extract_hdr/3 rejoins both pairs.

[
  %VocabularyEntry{
    label: :hdr,
    aliases: ["HDR10+", "HDR10Plus", "HDR10-Plus"],
    canonical: "HDR10+",
    confidence: 0.95,
    title_zone_bonus: -0.1,
    metadata_zone_bonus: 0.0
  },
  %VocabularyEntry{
    label: :hdr,
    aliases: ["HDR10"],
    canonical: "HDR10",
    confidence: 0.95,
    title_zone_bonus: -0.1,
    metadata_zone_bonus: 0.0
  },
  %VocabularyEntry{
    label: :hdr,
    aliases: ["HDR"],
    canonical: "HDR",
    confidence: 0.9,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.0
  },
  %VocabularyEntry{
    label: :hdr,
    aliases: ["HLG"],
    canonical: "HLG",
    confidence: 0.9,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.0
  },
  %VocabularyEntry{
    label: :hdr,
    aliases: ["DolbyVision", "DoVi"],
    canonical: "Dolby Vision",
    confidence: 0.95,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :hdr,
    aliases: ["DV"],
    canonical: "Dolby Vision",
    confidence: 0.8,
    title_zone_bonus: -0.5,
    metadata_zone_bonus: 0.1
  }
]
