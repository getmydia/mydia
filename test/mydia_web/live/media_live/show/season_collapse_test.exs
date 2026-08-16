defmodule MydiaWeb.MediaLive.Show.SeasonCollapseTest do
  # async: false — connected LiveView tests hit the Postgres non-shared
  # sandbox, which hides test rows from the mount process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Playback.Progress
  alias Mydia.Repo
  alias MydiaWeb.MediaLive.Show.Helpers
  alias MydiaWeb.MediaLive.Show.SeasonComponents

  defp episode(attrs) do
    struct!(
      %Episode{monitored: true, air_date: ~D[2024-01-01], media_files: [], downloads: []},
      attrs
    )
  end

  setup %{conn: conn} do
    # The app disables Oban in test (engine: false), so Oban.insert cannot run
    # from the LiveView process. Start an isolated, manual-mode instance so the
    # auto-search click in the bubbling guard can enqueue without a live queue.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Repo, engine: engine, testing: :manual})

    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  describe "default_expanded_seasons/2" do
    test "expands the next episode's season" do
      media_item = %{
        type: "tv_show",
        episodes: [episode(season_number: 1), episode(season_number: 2)]
      }

      assert Helpers.default_expanded_seasons(media_item, episode(season_number: 2)) ==
               MapSet.new([2])
    end

    test "falls back to the newest season when there is no next episode" do
      media_item = %{
        type: "tv_show",
        episodes: [
          episode(season_number: 1),
          episode(season_number: 3),
          episode(season_number: 2)
        ]
      }

      assert Helpers.default_expanded_seasons(media_item, nil) == MapSet.new([3])
    end

    test "falls back to the newest season when the next episode names an unknown season" do
      media_item = %{type: "tv_show", episodes: [episode(season_number: 1)]}

      assert Helpers.default_expanded_seasons(media_item, episode(season_number: 9)) ==
               MapSet.new([1])
    end

    test "expands nothing for a non-tv item or a show with no episodes" do
      assert Helpers.default_expanded_seasons(%{type: "movie", episodes: []}, nil) == MapSet.new()

      assert Helpers.default_expanded_seasons(%{type: "tv_show", episodes: []}, nil) ==
               MapSet.new()
    end
  end

  describe "season_episode_counts/1" do
    test "counts downloaded, missing, upcoming, and total in one pass" do
      episodes = [
        episode(media_files: [%MediaFile{}]),
        episode(air_date: ~D[2024-01-01], media_files: []),
        episode(air_date: Date.add(Date.utc_today(), 30), media_files: []),
        episode(air_date: nil, media_files: [])
      ]

      assert Helpers.season_episode_counts(episodes) == %{
               available: 1,
               missing: 1,
               upcoming: 1,
               total: 4
             }
    end

    test "a future air_date counts as upcoming, never missing" do
      episodes = [episode(air_date: Date.add(Date.utc_today(), 1), media_files: [])]

      assert Helpers.season_episode_counts(episodes) == %{
               available: 0,
               missing: 0,
               upcoming: 1,
               total: 1
             }
    end
  end
end
