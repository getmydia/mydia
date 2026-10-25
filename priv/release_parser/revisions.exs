alias Mydia.Library.ReleaseParser.VocabularyEntry

# Release revision flags: a PROPER fixes another group's release, a
# REPACK (or RERIP) fixes the group's own. QualityExtractor turns them
# into the `proper` / `repack` booleans. A title word ("The.Proper.Way")
# is reclaimed by Resolver.reclaim_title_words/2, so the title-zone
# penalty only has to keep these below a metadata-zone tag.

[
  %VocabularyEntry{
    label: :proper,
    aliases: ["PROPER"],
    canonical: "PROPER",
    confidence: 0.9,
    title_zone_bonus: -0.1,
    metadata_zone_bonus: 0.0
  },
  %VocabularyEntry{
    label: :repack,
    aliases: ["REPACK", "RERIP"],
    canonical: "REPACK",
    confidence: 0.9,
    title_zone_bonus: -0.1,
    metadata_zone_bonus: 0.0
  }
]
