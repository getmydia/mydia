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

  describe "season_header/1 chip" do
    test "shows the missing chip first" do
      html = render_season_header([episode(air_date: ~D[2024-01-01], media_files: [])])

      assert html =~ "1 missing"
    end

    test "a season with only future episodes reads upcoming, never missing" do
      html =
        render_season_header([episode(air_date: Date.add(Date.utc_today(), 30), media_files: [])])

      assert html =~ "1 upcoming"
      refute html =~ "missing"
    end

    test "a fully available season reads complete" do
      html = render_season_header([episode(media_files: [%MediaFile{}])])

      assert html =~ "complete"
    end

    test "an all-TBA season renders no chip" do
      html = render_season_header([episode(air_date: nil, media_files: [])])

      refute html =~ "missing"
      refute html =~ "upcoming"
      refute html =~ "complete"
    end
  end

  defp render_season_header(episodes) do
    render_component(&SeasonComponents.season_header/1,
      season_number: 1,
      episodes: episodes,
      expanded?: false,
      auto_searching_season: nil,
      rescanning_season: nil
    )
  end

  describe "collapse at mount and on click" do
    test "expands the next episode's season at mount and collapses the rest", %{conn: conn} do
      {media_item, _ep_1, _ep_2} = two_season_show()

      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      assert has_element?(view, "#season-1-episodes")
      refute has_element?(view, "#season-2-episodes")
    end

    test "a fully watched show falls back to the newest season", %{conn: conn, admin: admin} do
      {media_item, ep_1, ep_2} = two_season_show()

      mark_watched!(admin, ep_1)
      mark_watched!(admin, ep_2)

      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      assert has_element?(view, "#season-2-episodes")
      refute has_element?(view, "#season-1-episodes")
    end

    test "the toggle expands and collapses a season", %{conn: conn} do
      {media_item, _ep_1, _ep_2} = two_season_show()

      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      refute has_element?(view, "#season-2-episodes")

      view |> element("#season-2-toggle") |> render_click()
      assert has_element?(view, "#season-2-episodes")

      view |> element("#season-2-toggle") |> render_click()
      refute has_element?(view, "#season-2-episodes")
    end

    test "clicking a season's auto search never toggles the season", %{conn: conn} do
      {media_item, _ep_1, _ep_2} = two_season_show()

      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      refute has_element?(view, "#season-2-episodes")
      view |> element("#season-2-auto-search") |> render_click()
      refute has_element?(view, "#season-2-episodes")

      assert has_element?(view, "#season-1-episodes")
      view |> element("#season-1-auto-search") |> render_click()
      assert has_element?(view, "#season-1-episodes")
    end
  end

  # A two-season show, one file per season, so the next episode is season 1's
  # first episode (episodes are ordered season asc, episode asc, then filtered
  # to those with files).
  defp two_season_show do
    media_item = media_item_fixture(%{type: "tv_show"})

    ep_1 = episode_fixture(%{media_item_id: media_item.id, season_number: 1, episode_number: 1})
    media_file_fixture(%{episode_id: ep_1.id})

    ep_2 = episode_fixture(%{media_item_id: media_item.id, season_number: 2, episode_number: 1})
    media_file_fixture(%{episode_id: ep_2.id})

    {media_item, ep_1, ep_2}
  end

  defp mark_watched!(user, episode) do
    %Progress{}
    |> Progress.changeset(
      %{
        user_id: user.id,
        episode_id: episode.id,
        position_seconds: 0,
        duration_seconds: 100,
        watched: true
      },
      authoritative_watched: true
    )
    |> Repo.insert!()
  end
end
