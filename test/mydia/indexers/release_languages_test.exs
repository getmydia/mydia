defmodule Mydia.Indexers.ReleaseLanguagesTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.ReleaseLanguages

  # {title, original language, expected languages, expected assumed?}
  @cases [
    {"[BlackRabbit] Kaiju Garden (2021) - S02 [Bluray-1080p][Opus 2.0][Dual Audio][AV1]", "ja",
     ["en", "ja"], false},
    {"Kaiju.Garden.S02.1080p.BluRay.REMUX.Dual-Audio.AVC.FLAC2.0-RUDY", "ja", ["en", "ja"],
     false},
    {"Kaiju.Garden.S03E01.1080p.WEBRip.Dual.Audio.AV1-Breeze.mkv", "ja", ["en", "ja"], false},
    {"Kaiju.Garden.S03E03.Home.1080p.CR.WEB-DL.DUAL.AAC2.0.H.264-VARYG.mkv", "ja", ["en", "ja"],
     false},
    {"[TRC] Kaiju Garden - S02 [English Dub] [CR WEB-RIP 1080p HEVC-10 AAC]", "ja", ["en"],
     false},
    {"Kaiju.Garden.S03E04.1080p.CR.WEB-DL.JPN.AAC2.0.H.264.MSubs-ToonsHub.mkv", "ja", ["ja"],
     false},
    {"Kaiju Garden S02 Parte 1 (2023) 1080p WEBDL x265 iTALiAN AC3 iDN_CreW", "ja", ["it"],
     false},
    {"[NekoLATAM].Kaiju.Garden.S01E23.WEBDL-1080p.x264.AAC.2.0[ES+JA].[Spanish.Latino].mkv", "ja",
     ["es", "ja"], false},
    {"Kaiju Garden S02 MULTi 1080p WEB x264 AAC -Tsundere-Raws (CR)", "ja", ["ja"], false},
    {"Paper.Lantern.Club.2024.TRUEFRENCH.1080p.WEB.x264", "en", ["fr"], false},
    {"Paper.Lantern.Club.2024.1080p.WEB.x264.Hindi.Dubbed", "en", ["hi"], false},
    # Subtitle markers must not read as audio.
    {"[Feibanyama] Kaiju Garden S02 [BILIBILI WebRip 2160p HEVC OPUS Multi-Subs]", "ja", ["ja"],
     true},
    {"Kaiju Garden S03E06 VOSTFR 1080p WEB x264 AAC -Tsundere-Raws (CR).mkv", "ja", ["ja"], true},
    {"Kaiju Garden S03E09 SUBFRENCH 1080p CR WEB-DL AAC2.0 H.264-Tsundere-Raws.mkv", "ja", ["ja"],
     true},
    {"Paper.Lantern.Club.2024.1080p.WEB.x264.ESub", "en", ["en"], true},
    # No language token at all.
    {"Kaiju.Garden.S02.1080p.CR.WEB-DL.AAC2.0.H.264-VARYG", "ja", ["ja"], true},
    # Codec names in a bracket combo are not languages.
    {"Paper.Lantern.Club.2024.1080p.BluRay.[DTS+AAC].x264", "en", ["en"], true},
    # A group name that merely contains DUAL is not a dual-audio tag.
    {"Paper.Lantern.Club.2024.1080p.WEB.x264-DUALiTY", "en", ["en"], true},
    # German abbreviations, not just the full word.
    {"Paper.Lantern.Club.2024.GER.DL.1080p.BluRay.x264", "en", ["de"], false},
    {"Paper.Lantern.Club.2024.DEU.1080p.WEB.x264", "en", ["de"], false}
  ]

  for {{title, original, languages, assumed?}, index} <- Enum.with_index(@cases) do
    test "case #{index}: #{title}" do
      detected = ReleaseLanguages.detect(unquote(title), unquote(original))

      assert detected.languages == unquote(languages)
      assert detected.assumed? == unquote(assumed?)
    end
  end

  test "dual audio with an unknown original still reports English" do
    assert ReleaseLanguages.detect("Kaiju.Garden.S01.Dual.Audio.1080p", nil) ==
             %ReleaseLanguages{languages: ["en"], assumed?: false}
  end

  test "an untagged title with an unknown original detects nothing" do
    assert ReleaseLanguages.detect("Kaiju.Garden.S01.1080p", nil) ==
             %ReleaseLanguages{languages: [], assumed?: true}
  end

  test "a nil title is treated as untagged" do
    assert ReleaseLanguages.detect(nil, "ja") == %ReleaseLanguages{
             languages: ["ja"],
             assumed?: true
           }
  end

  test "an invalid UTF-8 title is treated as untagged instead of raising" do
    assert ReleaseLanguages.detect(<<0xFF, 0xFE, "DUAL">>, "ja").assumed?
  end
end
