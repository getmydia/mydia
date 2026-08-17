defmodule Mydia.Library.ReleaseParser.AbsoluteEpisodeTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.ReleaseParser.TargetContext

  defp anime_target do
    %TargetContext{
      type: :tv_show,
      title: "Black Clover",
      category: "anime_series",
      max_absolute_number: 170,
      known_seasons: [0, 1]
    }
  end

  defp ordinary_target do
    %TargetContext{
      type: :tv_show,
      title: "Black Clover",
      category: "tv_show",
      max_absolute_number: nil,
      known_seasons: [0, 1]
    }
  end

  test "resolves a bare number for an anime target" do
    result =
      ReleaseParser.parse("[SubsPlease] Black Clover - 170 (1080p) [A1B2C3].mkv",
        target: anime_target()
      )

    assert result.absolute_episode == 170
  end

  test "ignores a bare number for a non-anime target" do
    result =
      ReleaseParser.parse(
        "[SubsPlease] Black Clover - 170 (1080p) [A1B2C3].mkv",
        target: ordinary_target()
      )

    assert result.absolute_episode == nil
  end

  test "ignores a bare number above the show's absolute range" do
    result = ReleaseParser.parse("Black Clover - 2049 (1080p).mkv", target: anime_target())

    assert result.absolute_episode == nil
  end

  test "does not treat resolution or codec digits as episodes" do
    result = ReleaseParser.parse("Black Clover 1080p x264 AAC.mkv", target: anime_target())

    assert result.absolute_episode == nil
  end

  test "an explicit season marker wins over the bare number" do
    result = ReleaseParser.parse("Black Clover S01E52 1080p.mkv", target: anime_target())

    assert result.season == 1
    assert result.episodes == [52]
    assert result.absolute_episode == nil
  end

  test "ignores a bare number when category is present but not anime" do
    target = %{ordinary_target() | max_absolute_number: 170}

    result =
      ReleaseParser.parse(
        "[SubsPlease] Black Clover - 170 (1080p) [A1B2C3].mkv",
        target: target
      )

    assert result.absolute_episode == nil
  end

  test "does not pick up a numeric title as the episode number" do
    result =
      ReleaseParser.parse("[Erai-raws] 86 - Eighty Six - 12 [1080p].mkv", target: anime_target())

    assert result.absolute_episode == 12
  end

  test "does not pick up a numeric title's leading digits as the episode number" do
    result =
      ReleaseParser.parse("[HorribleSubs] 91 Days - 07 [720p].mkv", target: anime_target())

    assert result.absolute_episode == 7
  end

  test "does not pick up a sequel number in the title as the episode number" do
    result =
      ReleaseParser.parse(
        "[SubsPlease] Log Horizon 2 - 05 (1080p) [ABCDEF].mkv",
        target: anime_target()
      )

    assert result.absolute_episode == 5
  end

  test "does not pick up a part number in the title as the episode number" do
    result = ReleaseParser.parse("Black Clover Part 2 - 05.mkv", target: anime_target())

    assert result.absolute_episode == 5
  end

  test "does not pick up a frame rate as the episode number" do
    result =
      ReleaseParser.parse("Black Clover 10bit 24 fps - 05.mkv", target: anime_target())

    assert result.absolute_episode == 5
  end

  test "does not pick up an audio channel layout as the episode number" do
    result = ReleaseParser.parse("Black Clover FLAC 2.0 - 05.mkv", target: anime_target())

    assert result.absolute_episode == 5
  end

  test "resolves a space-separated bare number with no dash at all" do
    result =
      ReleaseParser.parse("[SubsPlease] Black Clover 170 (1080p) [A1B2C3].mkv",
        target: anime_target()
      )

    assert result.absolute_episode == 170
  end

  test "resolves a trailing bare number with no other anchors" do
    result = ReleaseParser.parse("Black Clover 170.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves a dot-separated bare number with no dash" do
    result = ReleaseParser.parse("Black Clover.170.1080p.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves a bare number that precedes the dash instead of following it" do
    result = ReleaseParser.parse("Black Clover 05 - 1080p.mkv", target: anime_target())

    assert result.absolute_episode == 5
  end

  test "prefers the dash-adjacent episode number over a later embedded digit" do
    result =
      ReleaseParser.parse(
        "[Group] Black Clover - 05 - The Title 12 [1080p].mkv",
        target: anime_target()
      )

    assert result.absolute_episode == 5
  end

  test "resolves through a compound-dash-split quality tag with no separating dash" do
    result =
      ReleaseParser.parse("Black Clover 170 DTS-HD 1080p.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves through separate audio words with no separating dash" do
    result = ReleaseParser.parse("Black Clover 170 DTS HD 1080p.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves through a codec tag with no separating dash" do
    result = ReleaseParser.parse("Black Clover 170 x264 1080p.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves through a trailing codec tag with no other anchors" do
    result = ReleaseParser.parse("Black Clover 170 HEVC.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves through a trailing audio tag with no other anchors" do
    result = ReleaseParser.parse("Black Clover 170 AAC.mkv", target: anime_target())

    assert result.absolute_episode == 170
  end

  test "resolves a low episode number through a trailing audio tag" do
    result = ReleaseParser.parse("Black Clover 05 AAC.mkv", target: anime_target())

    assert result.absolute_episode == 5
  end

  test "resolves a low episode number through a trailing codec tag" do
    result = ReleaseParser.parse("Black Clover 05 HEVC.mkv", target: anime_target())

    assert result.absolute_episode == 5
  end
end
