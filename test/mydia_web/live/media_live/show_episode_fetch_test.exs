defmodule MydiaWeb.MediaLive.ShowEpisodeFetchTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataCacheHelpers

  alias Mydia.Jobs.EpisodeFetch
  alias Mydia.Repo

  setup %{conn: conn} do
    item =
      media_item_fixture(%{
        type: "tv_show",
        title: "The Slow Lantern",
        year: 2021,
        tmdb_id: 910_101
      })

    warm_recommendations_cache(910_101, :tv_show, [])

    %{conn: log_in_user(conn, admin_user_fixture()), item: item}
  end

  defp refreshed_event(id),
    do: %{type: "media_item.episodes_refreshed", resource_type: "media_item", resource_id: id}

  test "shows the placeholder while a fetch is pending", %{conn: conn, item: item} do
    {:ok, _job} = EpisodeFetch.enqueue(item, [])

    {:ok, view, _html} = live(conn, ~p"/tv/#{item.id}")

    assert has_element?(view, "#episodes-fetching")
  end

  test "episodes_refreshed event replaces the placeholder", %{conn: conn, item: item} do
    {:ok, _job} = EpisodeFetch.enqueue(item, [])
    {:ok, view, _html} = live(conn, ~p"/tv/#{item.id}")
    assert has_element?(view, "#episodes-fetching")

    episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 1})
    send(view.pid, {:event_created, refreshed_event(item.id)})

    refute has_element?(view, "#episodes-fetching")
    assert has_element?(view, "#season-1")
  end

  test "a discarded job shows the normal empty state", %{conn: conn, item: item} do
    {:ok, job} = EpisodeFetch.enqueue(item, [])
    job |> Ecto.Changeset.change(state: "discarded") |> Repo.update!()

    {:ok, view, _html} = live(conn, ~p"/tv/#{item.id}")

    refute has_element?(view, "#episodes-fetching")
  end

  test "unrelated events do not reload", %{conn: conn, item: item} do
    {:ok, _job} = EpisodeFetch.enqueue(item, [])
    {:ok, view, _html} = live(conn, ~p"/tv/#{item.id}")

    send(view.pid, {:event_created, refreshed_event(Ecto.UUID.generate())})

    assert has_element?(view, "#episodes-fetching")
  end
end
