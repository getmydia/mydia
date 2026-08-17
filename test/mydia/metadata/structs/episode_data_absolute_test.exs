defmodule Mydia.Metadata.Structs.EpisodeDataAbsoluteTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Structs.EpisodeData

  # Shape captured from https://relay.mydia.dev/tvdb/seasons/720595/extended
  # (Black Clover, official ordering, season 1).
  defp tvdb_episode do
    %{
      "id" => 6_832_458,
      "seasonNumber" => 1,
      "number" => 52,
      "absoluteNumber" => 52,
      "name" => "Whoever's Strongest Wins",
      "aired" => "2018-10-02",
      "runtime" => 25
    }
  end

  test "carries absoluteNumber through as absolute_number" do
    assert %EpisodeData{absolute_number: 52} = EpisodeData.from_tvdb_response(tvdb_episode())
  end

  test "carries the TVDB episode id through as a string" do
    assert %EpisodeData{provider_episode_id: "6832458"} =
             EpisodeData.from_tvdb_response(tvdb_episode())
  end

  test "tolerates a missing absoluteNumber" do
    episode = Map.delete(tvdb_episode(), "absoluteNumber")

    assert %EpisodeData{absolute_number: nil, provider_episode_id: "6832458"} =
             EpisodeData.from_tvdb_response(episode)
  end

  test "TMDB responses leave both nil" do
    assert %EpisodeData{absolute_number: nil, provider_episode_id: nil} =
             EpisodeData.from_api_response(%{"season_number" => 1, "episode_number" => 1})
  end

  test "missing id results in nil provider_episode_id" do
    episode = Map.delete(tvdb_episode(), "id")

    assert %EpisodeData{provider_episode_id: nil} =
             EpisodeData.from_tvdb_response(episode)
  end

  test "empty string id results in nil to prevent index collision" do
    episode = Map.put(tvdb_episode(), "id", "")

    assert %EpisodeData{provider_episode_id: nil} =
             EpisodeData.from_tvdb_response(episode)
  end
end
