defmodule MydiaWeb.MediaLive.Show.TimelineVisibilityTest do
  @moduledoc """
  The per-title timeline reads events by resource, and playback events record
  `resource_type: "media_item"`. Without viewer scoping a guest sees every
  other account's watch activity for the title.
  """

  # Connected LiveView tests must stay sync: the Postgres sandbox is only shared
  # with the mount process when the case is not async.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers
  import MydiaWeb.AuthHelpers

  alias Mydia.Events

  setup do
    # The app disables Oban in test (engine: false), so Oban.insert cannot run
    # from the LiveView process. Start an isolated, manual-mode instance so the
    # recommendations load can enqueue without a live queue.
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    :ok
  end

  test "a guest's timeline omits another account's playback", %{conn: conn} do
    guest = user_fixture(%{role: "guest"})
    other = user_fixture(%{role: "guest"})
    show = seed_show()

    playback_event(other, show, "someone-elses-player")
    playback_event(guest, show, "this-guests-player")

    html =
      conn
      |> log_in_user(guest)
      |> render_show(show)

    assert html =~ "this-guests-player"
    refute html =~ "someone-elses-player"
  end

  test "a guest's timeline still shows the title being added", %{conn: conn} do
    guest = user_fixture(%{role: "guest"})
    show = seed_show()

    html =
      conn
      |> log_in_user(guest)
      |> render_show(show)

    # media_item_fixture goes through Media.create_media_item/2, which records
    # media_item.added, and Events.create_event_async/1 writes synchronously
    # under the SQL sandbox.
    assert html =~ "Added to library"
  end

  test "an admin's timeline is unchanged", %{conn: conn} do
    other = user_fixture(%{role: "guest"})
    show = seed_show()

    playback_event(other, show, "someone-elses-player")

    html =
      conn
      |> log_in_user(admin_user_fixture())
      |> render_show(show)

    assert html =~ "someone-elses-player"
  end

  defp seed_show do
    tmdb_id = unique_provider_id()

    show =
      media_item_fixture(%{
        type: "tv_show",
        title: "Detectorists",
        year: 2014,
        tmdb_id: tmdb_id
      })

    episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

    warm_recommendations_cache(tmdb_id, :tv_show, [
      %{
        "id" => unique_provider_id(),
        "name" => "Rev.",
        "first_air_date" => "2010-06-28",
        "poster_path" => "/p.jpg"
      }
    ])

    show
  end

  defp playback_event(user, show, origin) do
    {:ok, event} =
      Events.create_event(%{
        category: "playback",
        type: "playback.started",
        actor_type: :user,
        actor_id: user.id,
        resource_type: "media_item",
        resource_id: show.id,
        metadata: %{"origin" => origin}
      })

    event
  end

  defp render_show(conn, show) do
    {:ok, view, _html} = live(conn, ~p"/media/#{show.id}")
    render_async(view, 5000)
    render(view)
  end
end
