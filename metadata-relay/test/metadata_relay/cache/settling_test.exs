defmodule MetadataRelay.Cache.SettlingTest do
  use ExUnit.Case, async: true

  alias MetadataRelay.Cache.Settling

  # Mirrored case for case by relay-worker/test/cache/key.test.ts.
  @today ~D[2026-09-14]
  @six_hours :timer.hours(6)

  @tvdb_season_key "GET:/tvdb/seasons/2247557/extended:meta=translations"
  @tvdb_episode_key "GET:/tvdb/episodes/11767188/extended:meta=translations"
  @tmdb_season_key "GET:/tmdb/tv/shows/97546/4:"

  defp tvdb_season(episodes), do: Jason.encode!(%{"data" => %{"id" => 1, "episodes" => episodes}})

  describe "TVDB season" do
    test "an upcoming placeholder episode makes the season settling" do
      body = tvdb_season([%{"aired" => "2026-09-23", "name" => "TBA "}])
      assert Settling.ttl(@tvdb_season_key, body, @today) == @six_hours
    end

    test "an episode aired 14 days ago still counts" do
      body = tvdb_season([%{"aired" => "2026-08-31", "name" => "Harbor Lights"}])
      assert Settling.ttl(@tvdb_season_key, body, @today) == @six_hours
    end

    test "a season whose episodes all aired more than 14 days ago keeps the path TTL" do
      body = tvdb_season([%{"aired" => "2026-08-30", "name" => "Harbor Lights"}])
      assert Settling.ttl(@tvdb_season_key, body, @today) == nil
    end

    test "an undated placeholder episode is settling" do
      body = tvdb_season([%{"aired" => nil, "name" => "TBA"}])
      assert Settling.ttl(@tvdb_season_key, body, @today) == @six_hours
    end

    test "an undated special with a real name is not settling" do
      body = tvdb_season([%{"aired" => nil, "name" => "Behind the Lighthouse"}])
      assert Settling.ttl(@tvdb_season_key, body, @today) == nil
    end

    test "an undated episode with a blank or numbered placeholder name is settling" do
      blank = tvdb_season([%{"aired" => nil, "name" => ""}])
      numbered = tvdb_season([%{"aired" => nil, "name" => "Episode #8"}])

      assert Settling.ttl(@tvdb_season_key, blank, @today) == @six_hours
      assert Settling.ttl(@tvdb_season_key, numbered, @today) == @six_hours
    end
  end

  describe "TVDB episode" do
    test "an upcoming episode is settling, an old one is not" do
      upcoming = Jason.encode!(%{"data" => %{"aired" => "2026-09-23", "name" => "TBA "}})
      old = Jason.encode!(%{"data" => %{"aired" => "2019-03-01", "name" => "Quiet Tide"}})

      assert Settling.ttl(@tvdb_episode_key, upcoming, @today) == @six_hours
      assert Settling.ttl(@tvdb_episode_key, old, @today) == nil
    end
  end

  describe "TMDB season" do
    test "a numbered placeholder airing next week is settling, a finished season is not" do
      upcoming =
        Jason.encode!(%{"episodes" => [%{"air_date" => "2026-09-22", "name" => "Episode 8"}]})

      finished =
        Jason.encode!(%{"episodes" => [%{"air_date" => "2019-03-01", "name" => "Quiet Tide"}]})

      assert Settling.ttl(@tmdb_season_key, upcoming, @today) == @six_hours
      assert Settling.ttl(@tmdb_season_key, finished, @today) == nil
    end
  end

  describe "anything else" do
    test "other paths keep their TTL even with an upcoming episode in the body" do
      body = tvdb_season([%{"aired" => "2026-09-23", "name" => "TBA"}])

      assert Settling.ttl("GET:/tvdb/series/1/extended:", body, @today) == nil
      assert Settling.ttl("GET:/tmdb/tv/shows/97546:", body, @today) == nil
      assert Settling.ttl("GET:/tmdb/tv/shows/97546/images:", body, @today) == nil
    end

    test "an undecodable or unexpected body keeps the path TTL" do
      assert Settling.ttl(@tvdb_season_key, "not json", @today) == nil
      assert Settling.ttl(@tvdb_season_key, Jason.encode!([1, 2]), @today) == nil

      assert Settling.ttl(
               @tvdb_season_key,
               Jason.encode!(%{"data" => %{"episodes" => "nope"}}),
               @today
             ) == nil
    end
  end
end
