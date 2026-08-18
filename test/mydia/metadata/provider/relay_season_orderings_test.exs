defmodule Mydia.Metadata.Provider.RelaySeasonOrderingsTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.Relay

  # Shape captured from https://relay.mydia.dev/tvdb/series/331753/extended
  # (Black Clover). Eight season records across three orderings.
  defp seasons do
    [
      %{"id" => 720_594, "number" => 0, "type" => %{"type" => "official"}, "episodeCount" => 19},
      %{"id" => 720_595, "number" => 1, "type" => %{"type" => "official"}, "episodeCount" => 170},
      %{"id" => 1_750_419, "number" => 0, "type" => %{"type" => "dvd"}, "episodeCount" => 27},
      %{"id" => 1_750_420, "number" => 1, "type" => %{"type" => "dvd"}, "episodeCount" => 51},
      %{"id" => 1_837_386, "number" => 2, "type" => %{"type" => "dvd"}, "episodeCount" => 51},
      %{"id" => 1_837_387, "number" => 3, "type" => %{"type" => "dvd"}, "episodeCount" => 52},
      %{"id" => 1_892_353, "number" => 4, "type" => %{"type" => "dvd"}, "episodeCount" => 16},
      %{
        "id" => 1_750_418,
        "number" => 1,
        "type" => %{"type" => "absolute"},
        "episodeCount" => 170
      }
    ]
  end

  test "official ordering yields one 170-episode season" do
    result = Relay.transform_tvdb_seasons(seasons(), "official")

    assert Enum.map(result, & &1["season_number"]) == [0, 1]
    assert Enum.find(result, &(&1["season_number"] == 1))["episode_count"] == 170
  end

  test "dvd ordering yields four real seasons plus specials" do
    result = Relay.transform_tvdb_seasons(seasons(), "dvd")

    assert Enum.map(result, & &1["season_number"]) == [0, 1, 2, 3, 4]

    assert result
           |> Enum.reject(&(&1["season_number"] == 0))
           |> Enum.map(& &1["episode_count"]) == [51, 51, 52, 16]
  end

  test "dvd seasons carry their own tvdb_season_id" do
    result = Relay.transform_tvdb_seasons(seasons(), "dvd")

    assert Enum.find(result, &(&1["season_number"] == 2))["tvdb_season_id"] == 1_837_386
  end

  test "available_orderings/1 summarises every ordering" do
    assert Relay.available_orderings(seasons()) == %{
             "official" => [19, 170],
             "dvd" => [27, 51, 51, 52, 16],
             "absolute" => [170]
           }
  end
end
