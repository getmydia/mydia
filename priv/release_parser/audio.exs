alias Mydia.Library.ReleaseParser.VocabularyEntry

# Audio codec / format tokens. Compound tokens like "DTS-HD" and "DTS-X"
# are split by the tokenizer's dash allow-list — after that split the
# `DTS` token alone may match this vocab, so the resolver in Unit 5 is
# responsible for re-joining adjacent tokens when needed. For now we
# accept the post-split forms.
#
# `MA` is a very short ambiguous token (could be the streaming service
# "Movies Anywhere" or DTS-HD MA channel info), so it carries a heavy
# title-zone penalty.

# Releases glue the channel layout onto the codec (`AAC2.0`, `DDP5.1`,
# `DTS-HD5.1`, `DD+7.1`). The tokenizer splits on the dot, so the codec
# token arrives as `AAC2` (or `AAC20` when the dot was dropped), and the
# QualityExtractor reads the digits back off it.
with_channels = fn name ->
  [name] ++
    Enum.map(0..9, &"#{name}#{&1}") ++
    for(a <- 0..9, b <- 0..9, do: "#{name}#{a}#{b}")
end

[
  %VocabularyEntry{
    label: :audio,
    aliases: with_channels.("DTS-HD") ++ ["DTS-HD.MA", "DTSHDMA", "DTSHD"],
    canonical: "DTS-HD MA",
    confidence: 0.95,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :audio,
    aliases: ["DTS-X", "DTSX"],
    canonical: "DTS-X",
    confidence: 0.95,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :audio,
    aliases: with_channels.("DTS"),
    canonical: "DTS",
    confidence: 0.9,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.0
  },
  # DDP / DD / EAC3 / AC3. Tokenizer splits on dots, so `DDP5.1` arrives
  # as two tokens (`DDP5` and `1`); the extractor re-joins adjacent
  # channel numbers. A trailing `D` (`AC3D`, `EAC3D`) marks a German dub.
  %VocabularyEntry{
    label: :audio,
    aliases:
      ["EAC3", "E-AC3", "E-AC-3", "EAC3D"] ++ with_channels.("DDP") ++ with_channels.("DD+"),
    canonical: "Dolby Digital Plus",
    confidence: 0.92,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :audio,
    aliases: ["AC3", "AC3D"] ++ with_channels.("DD"),
    canonical: "Dolby Digital",
    confidence: 0.88,
    title_zone_bonus: -0.3,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :audio,
    aliases: with_channels.("TrueHD"),
    canonical: "TrueHD",
    confidence: 0.95,
    title_zone_bonus: -0.1,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :audio,
    aliases: ["Atmos"],
    canonical: "Dolby Atmos",
    confidence: 0.92,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :audio,
    aliases: ["AAC-LC"],
    canonical: "AAC-LC",
    confidence: 0.92,
    title_zone_bonus: -0.1,
    metadata_zone_bonus: 0.05
  },
  %VocabularyEntry{
    label: :audio,
    aliases: with_channels.("AAC"),
    canonical: "AAC",
    confidence: 0.9,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.0
  },
  %VocabularyEntry{
    label: :audio,
    aliases: with_channels.("OPUS"),
    canonical: "Opus",
    confidence: 0.9,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.0
  },
  # Dual-audio anime releases count their tracks (`2xFLAC`, `FLACx2`).
  %VocabularyEntry{
    label: :audio,
    aliases: with_channels.("FLAC") ++ ["2xFLAC", "FLACx2"],
    canonical: "FLAC",
    confidence: 0.9,
    title_zone_bonus: -0.2,
    metadata_zone_bonus: 0.0
  },
  %VocabularyEntry{
    label: :audio,
    aliases: ["MP3"],
    canonical: "MP3",
    confidence: 0.85,
    title_zone_bonus: -0.3,
    metadata_zone_bonus: 0.0
  }
]
