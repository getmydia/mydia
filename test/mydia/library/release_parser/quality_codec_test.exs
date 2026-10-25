defmodule Mydia.Library.ReleaseParser.QualityCodecTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser

  test "codec before a dashed multi-part group" do
    parsed = ReleaseParser.parse("Fake.Show.S01E01.1080p.WEB.x264-Some-Group")
    assert parsed.quality.codec == "x264"
    assert parsed.quality.source == "WEB-DL"
    assert parsed.release_group == "Some-Group"
  end

  test "codec before a bracketed group" do
    parsed = ReleaseParser.parse("Fake.Movie.2020.1080p.BluRay.x264-[GRP]")
    assert parsed.quality.codec == "x264"
    assert parsed.release_group == "GRP"
  end

  test "space-separated H 264" do
    assert ReleaseParser.parse("Fake Movie 2020 1080p WEB-DL AAC2 0 H 264-GRP").quality.codec ==
             "H.264"
  end

  test "a reposter's tag after the group is not the group" do
    parsed = ReleaseParser.parse("Fake.Show.S01E01.720p.HDTV.x264-GRP-RP")
    assert parsed.quality.codec == "x264"
    assert parsed.release_group == "GRP"

    parsed = ReleaseParser.parse("Fake.Show.S01E01.1080p.AMZN.WEB-DL.DDP5.1.H.264-GRP-xpost")
    assert parsed.quality.codec == "H.264"
    assert parsed.release_group == "GRP"
  end

  test "a dash run of language and audio tags after the codec is not a group" do
    parsed = ReleaseParser.parse("Fake-Words-Movie-(1990)-[DVDRip]-H264-Fra-Ac3-2-0-Eng-5-1")
    assert parsed.quality.codec == "H.264"
    assert parsed.release_group == nil
  end

  test "a bracketed bit depth after the codec is not a group" do
    parsed = ReleaseParser.parse("Fake Movie 2020 1080p HEVC-[10bit]")
    assert parsed.quality.codec == "H.265"
    assert parsed.release_group == nil
  end

  test "reposter tags are dropped without a codec before the group" do
    assert ReleaseParser.parse("Fake.Movie.2020.1080p.BluRay-GRP-RP").release_group == "GRP"
  end

  describe "a codec word inside a hyphenated title" do
    for {input, title, codec} <- [
          {"Route-264.2019.1080p.BluRay.x264-GRP", "Route-264", "x264"},
          {"Project-AV1.2021.1080p.WEB-DL.x264-GRP", "Project-AV1", "x264"},
          {"Agent-Xvid.S01E02.1080p.WEB-DL.x264-GRP", "Agent-Xvid", "x264"},
          {"Avc-Station.2019.1080p.BluRay.x265-GRP", "Avc-Station", "x265"},
          {"Code-Hevc.2020.1080p.WEB-DL.H.264-GRP", "Code-Hevc", "H.264"}
        ] do
      test "stays in the title: #{input}" do
        parsed = ReleaseParser.parse(unquote(input))
        assert parsed.title == unquote(title)
        assert parsed.quality.codec == unquote(codec)
      end
    end
  end

  test "codec dash-joined to a bit depth, audio or group word" do
    assert ReleaseParser.parse("[Fakesub] Some Show - 05 [WebRip 1080p HEVC-10bit AAC]").quality.codec ==
             "H.265"

    assert ReleaseParser.parse("[Fakesub]_Some_Show_07_(1280x720_x264-AAC)_[6B7FD717]").quality.codec ==
             "x264"

    assert ReleaseParser.parse("Some Show E76 2024 08 08 1080p WEB H264-GRP96 [TAG]").quality.codec ==
             "H.264"
  end

  test "codec in a comma-separated tag list" do
    assert ReleaseParser.parse("Fake Movie 2025 [HEVC, HDR10, WEB-DL 2160p] [Hybrid]").quality.codec ==
             "H.265"
  end

  test "dotted H.264 before a group that the pre-pass leaves alone" do
    assert ReleaseParser.parse("Fake.Show.S01E09.1080p.WEB-DL.H.264-GRP (Some Note, Multi-Subs)").quality.codec ==
             "H.264"
  end

  test "codec dash-joined after a source the vocabulary does not know" do
    assert ReleaseParser.parse("Some Show (Season 1) (2022) WEB-DLRip-AVC Ukr Eng").quality.codec ==
             "H.264"
  end
end
