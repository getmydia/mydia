defmodule MydiaWeb.MediaLive.Show.AutoSearchBypassTest do
  # Connected LiveView tests cannot be async under the PostgreSQL sandbox.
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Phoenix.LiveViewTest
  import Mydia.Factory
  import Mydia.MediaFixtures

  setup %{conn: conn} do
    # The Search buttons call Oban.insert/1 directly, which needs a running
    # Oban (test config sets engine: false).
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    {conn, user} = register_and_log_in_user(conn, %{role: "admin"})
    %{conn: conn, user: user}
  end

  test "the movie Search button skips the grab delay", %{conn: conn} do
    movie = insert(:media_item, %{type: "movie", title: "Glass Harbor", year: 2031})
    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

    render_click(view, "auto_search_download", %{})

    assert_enqueued(
      worker: Mydia.Jobs.MovieSearch,
      args: %{"mode" => "specific", "media_item_id" => movie.id, "bypass_delay" => true}
    )
  end

  test "the episode and season Search buttons skip the grab delay", %{conn: conn} do
    show = insert(:tv_show, %{title: "Lantern Vale"})

    episode =
      episode_fixture(%{
        media_item_id: show.id,
        season_number: 1,
        episode_number: 1,
        air_date: ~D[2031-01-01]
      })

    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")

    render_click(view, "auto_search_episode", %{"episode-id" => episode.id})
    render_click(view, "auto_search_season", %{"season-number" => "1"})

    assert_enqueued(
      worker: Mydia.Jobs.TVShowSearch,
      args: %{"mode" => "specific", "episode_id" => episode.id, "bypass_delay" => true}
    )

    assert_enqueued(
      worker: Mydia.Jobs.TVShowSearch,
      args: %{
        "mode" => "season",
        "media_item_id" => show.id,
        "season_number" => 1,
        "bypass_delay" => true
      }
    )
  end
end
