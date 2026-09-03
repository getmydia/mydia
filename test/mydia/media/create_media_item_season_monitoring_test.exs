defmodule Mydia.Media.CreateMediaItemSeasonMonitoringTest do
  use Mydia.DataCase, async: false

  import Ecto.Query

  alias Mydia.Media
  alias Mydia.Media.Episode

  setup do
    bypass = Bypass.open()
    tmdb_id = System.unique_integer([:positive])

    today = Date.utc_today()
    past_date = Date.add(today, -30) |> Date.to_iso8601()
    future_date = Date.add(today, 30) |> Date.to_iso8601()

    # Stub show metadata with Season 0, Season 1, and Season 2
    stub_tmdb_tv_show(bypass, tmdb_id, "Monitoring Test Show", [
      %{"season_number" => 0, "episode_count" => 1},
      %{"season_number" => 1, "episode_count" => 2},
      %{"season_number" => 2, "episode_count" => 2}
    ])

    # Season 0 (specials): 1 episode
    stub_tmdb_season(bypass, tmdb_id, 0, [
      %{
        "season_number" => 0,
        "episode_number" => 1,
        "name" => "Special 1",
        "air_date" => past_date
      }
    ])

    # Season 1: 2 past episodes
    stub_tmdb_season(bypass, tmdb_id, 1, [
      %{"season_number" => 1, "episode_number" => 1, "name" => "S01E01", "air_date" => past_date},
      %{"season_number" => 1, "episode_number" => 2, "name" => "S01E02", "air_date" => past_date}
    ])

    # Season 2: 1 past episode, 1 future episode
    stub_tmdb_season(bypass, tmdb_id, 2, [
      %{"season_number" => 2, "episode_number" => 1, "name" => "S02E01", "air_date" => past_date},
      %{
        "season_number" => 2,
        "episode_number" => 2,
        "name" => "S02E02",
        "air_date" => future_date
      }
    ])

    # Prevent TVDB lookup
    stub_tvdb_search_empty(bypass)

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }

    %{
      config: config,
      tmdb_id: tmdb_id,
      past_date: past_date,
      future_date: future_date
    }
  end

  describe "season_monitoring: \"future\"" do
    test "fetches all seasons, sets monitor_new_seasons: :all, and monitors only future episodes",
         %{config: config, tmdb_id: tmdb_id} do
      assert {:ok, media_item} =
               Media.create_media_item(
                 %{
                   title: "Monitoring Test Show",
                   type: "tv_show",
                   tmdb_id: tmdb_id,
                   metadata_source: :tmdb
                 },
                 config: config,
                 season_monitoring: "future"
               )

      assert media_item.monitor_new_seasons == :all

      episodes =
        Repo.all(
          from(e in Episode,
            where: e.media_item_id == ^media_item.id,
            order_by: [e.season_number, e.episode_number]
          )
        )

      # All 5 episodes across Season 0, 1, 2 must exist in DB
      assert length(episodes) == 5

      # Only S02E02 is future, so only it is monitored
      monitored_episodes = Enum.filter(episodes, & &1.monitored)
      assert length(monitored_episodes) == 1
      [future_ep] = monitored_episodes
      assert future_ep.season_number == 2
      assert future_ep.episode_number == 2

      # Specials and past episodes are unmonitored
      refute Enum.find(episodes, &(&1.season_number == 0)).monitored
      refute Enum.find(episodes, &(&1.season_number == 1 && &1.episode_number == 1)).monitored
      refute Enum.find(episodes, &(&1.season_number == 2 && &1.episode_number == 1)).monitored
    end
  end

  describe "season_monitoring: \"first\"" do
    test "fetches all seasons, sets monitor_new_seasons: :none, and monitors only Season 1",
         %{config: config, tmdb_id: tmdb_id} do
      assert {:ok, media_item} =
               Media.create_media_item(
                 %{
                   title: "Monitoring Test Show",
                   type: "tv_show",
                   tmdb_id: tmdb_id,
                   metadata_source: :tmdb
                 },
                 config: config,
                 season_monitoring: "first"
               )

      assert media_item.monitor_new_seasons == :none

      episodes =
        Repo.all(
          from(e in Episode,
            where: e.media_item_id == ^media_item.id,
            order_by: [e.season_number, e.episode_number]
          )
        )

      assert length(episodes) == 5

      # Only Season 1 episodes are monitored
      monitored_episodes = Enum.filter(episodes, & &1.monitored)
      assert length(monitored_episodes) == 2
      assert Enum.all?(monitored_episodes, &(&1.season_number == 1))

      # Season 0 and Season 2 episodes are unmonitored
      unmonitored = Enum.reject(episodes, & &1.monitored)
      assert length(unmonitored) == 3
      assert Enum.any?(unmonitored, &(&1.season_number == 0))
      assert Enum.all?(Enum.filter(unmonitored, &(&1.season_number == 2)), &(not &1.monitored))
    end
  end

  describe "season_monitoring: \"none\"" do
    test "fetches all seasons, sets monitor_new_seasons: :none, and monitors no episodes",
         %{config: config, tmdb_id: tmdb_id} do
      assert {:ok, media_item} =
               Media.create_media_item(
                 %{
                   title: "Monitoring Test Show",
                   type: "tv_show",
                   tmdb_id: tmdb_id,
                   metadata_source: :tmdb
                 },
                 config: config,
                 season_monitoring: "none"
               )

      assert media_item.monitor_new_seasons == :none

      episodes = Repo.all(from(e in Episode, where: e.media_item_id == ^media_item.id))
      assert length(episodes) == 5
      assert Enum.all?(episodes, fn e -> not e.monitored end)
    end
  end

  describe "season_monitoring: \"all\"" do
    test "fetches all seasons, sets monitor_new_seasons: :all, and monitors all non-special episodes",
         %{config: config, tmdb_id: tmdb_id} do
      assert {:ok, media_item} =
               Media.create_media_item(
                 %{
                   title: "Monitoring Test Show",
                   type: "tv_show",
                   tmdb_id: tmdb_id,
                   metadata_source: :tmdb
                 },
                 config: config,
                 season_monitoring: "all"
               )

      assert media_item.monitor_new_seasons == :all

      episodes = Repo.all(from(e in Episode, where: e.media_item_id == ^media_item.id))
      assert length(episodes) == 5

      # Season > 0 are monitored (2 in S1 + 2 in S2 = 4)
      monitored = Enum.filter(episodes, & &1.monitored)
      assert length(monitored) == 4
      assert Enum.all?(monitored, &(&1.season_number > 0))

      # Season 0 specials are unmonitored
      special = Enum.find(episodes, &(&1.season_number == 0))
      refute special.monitored
    end
  end

  describe "monitored: false" do
    test "unmonitored show creates all episodes unmonitored regardless of season_monitoring",
         %{config: config, tmdb_id: tmdb_id} do
      assert {:ok, media_item} =
               Media.create_media_item(
                 %{
                   title: "Monitoring Test Show",
                   type: "tv_show",
                   tmdb_id: tmdb_id,
                   metadata_source: :tmdb,
                   monitored: false
                 },
                 config: config,
                 season_monitoring: "all"
               )

      episodes = Repo.all(from(e in Episode, where: e.media_item_id == ^media_item.id))
      assert length(episodes) == 5
      assert Enum.all?(episodes, fn e -> not e.monitored end)
    end
  end

  # Helper functions
  defp stub_tmdb_tv_show(bypass, id, title, seasons) do
    body = %{
      "id" => id,
      "name" => title,
      "first_air_date" => "2021-03-04",
      "overview" => "x",
      "credits" => %{"cast" => [], "crew" => []},
      "seasons" => seasons,
      "genres" => []
    }

    Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp stub_tmdb_season(bypass, tmdb_id, season_number, episodes) do
    body = %{
      "season_number" => season_number,
      "name" => "Season #{season_number}",
      "episodes" => episodes
    }

    Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{tmdb_id}/#{season_number}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp stub_tvdb_search_empty(bypass) do
    Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => []}))
    end)
  end
end
