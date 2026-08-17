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
end
