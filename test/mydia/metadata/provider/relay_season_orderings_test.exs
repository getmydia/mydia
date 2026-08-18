defmodule Mydia.Metadata.Provider.RelaySeasonOrderingsTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Provider.Relay

  # Synthetic — NOT a real relay response. `episodeCount` is included here
  # purely to exercise `transform_tvdb_seasons/2`'s field mapping; the real
  # `/tvdb/series/{id}/extended` endpoint never populates that key (verified
  # live, 2026-08-17 — see `relay_season_orderings_test.exs`'s
  # `real_seasons/0` below for what TVDB actually sends). Every TVDB show's
  # stored `SeasonInfo.episode_count` is therefore 0 in production
  # (`relay.ex`'s `transform_tvdb_seasons/2`, `"episode_count" => s["episodeCount"] || 0`)
  # — a known, pre-existing, out-of-scope bug, not something these three
  # tests are claiming is real.
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

  # Real payload — captured live from
  # https://relay.mydia.dev/tvdb/series/331753/extended?meta=translations
  # (Black Clover) on 2026-08-17. Same ids/numbers/types as `seasons/0`
  # above, with the fabricated `episodeCount` keys removed: TVDB does not
  # send that field on this endpoint, for any season, in any ordering.
  defp real_seasons do
    [
      %{"id" => 720_594, "number" => 0, "type" => %{"type" => "official"}},
      %{"id" => 720_595, "number" => 1, "type" => %{"type" => "official"}},
      %{"id" => 1_750_419, "number" => 0, "type" => %{"type" => "dvd"}},
      %{"id" => 1_750_420, "number" => 1, "type" => %{"type" => "dvd"}},
      %{"id" => 1_837_386, "number" => 2, "type" => %{"type" => "dvd"}},
      %{"id" => 1_837_387, "number" => 3, "type" => %{"type" => "dvd"}},
      %{"id" => 1_892_353, "number" => 4, "type" => %{"type" => "dvd"}},
      %{"id" => 1_750_418, "number" => 1, "type" => %{"type" => "absolute"}}
    ]
  end

  test "available_orderings/1 reports season counts per ordering, not episode counts" do
    assert Relay.available_orderings(real_seasons()) == %{
             "official" => 2,
             "dvd" => 5,
             "absolute" => 1
           }
  end
end
