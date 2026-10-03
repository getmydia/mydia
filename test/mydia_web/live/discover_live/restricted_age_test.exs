defmodule MydiaWeb.DiscoverLive.RestrictedAgeTest do
  @moduledoc """
  End-to-end repros for #1000: an account limited to 12+ sees only titles
  within the limit on every Discover mode and on the dashboard, and a guest
  can still request an allowed title.
  """

  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.RelayStubs
  import Phoenix.LiveViewTest

  alias Mydia.MediaRequests
  alias Mydia.Media.RemoteSignals
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Structs.SearchResult

  setup %{conn: conn} do
    warm_genre_cache(:movie, [])
    warm_genre_cache(:tv_show, [])
    user = restricted_user_fixture(%{max_content_age: 12})
    %{conn: log_in_user(conn, user), user: user}
  end

  test "trending shows only titles within the limit", %{conn: conn} do
    warm_lantern_and_ledger()

    {:ok, view, _html} = live(conn, ~p"/discover")

    assert has_element?(view, "#discover-grid h3", "Lantern Vale")
    refute has_element?(view, "#discover-grid h3", "Crimson Ledger")
  end

  test "tv trending is filtered too", %{conn: conn} do
    ok = unique_provider_id()
    mature = unique_provider_id()
    signals(ok, :tv_show, "TV-PG", 8)
    signals(mature, :tv_show, "TV-MA", 17)

    warm_trending_cache(:tv_show, [
      %{"id" => ok, "name" => "Puddle Patrol"},
      %{"id" => mature, "name" => "Night Ward"}
    ])

    {:ok, view, _html} = live(conn, ~p"/discover?type=tv_show")

    assert has_element?(view, "#discover-grid h3", "Puddle Patrol")
    refute has_element?(view, "#discover-grid h3", "Night Ward")
  end

  test "search results are filtered", %{conn: conn} do
    ok = unique_provider_id()
    r = unique_provider_id()
    signals(ok, :movie, "G", 0)
    signals(r, :movie, "R", 17)

    warm_movie_search_cache("harbor", [], [
      %{"id" => ok, "title" => "Harbor Kites"},
      %{"id" => r, "title" => "Harbor Knives"}
    ])

    {:ok, view, _html} = live(conn, ~p"/discover?q=harbor")

    assert has_element?(view, "#discover-grid h3", "Harbor Kites")
    refute has_element?(view, "#discover-grid h3", "Harbor Knives")
  end

  test "popular is filtered", %{conn: conn} do
    ok = unique_provider_id()
    r = unique_provider_id()
    signals(ok, :movie, "PG", 8)
    signals(r, :movie, "R", 17)

    key = "curated:popular:movie:1"

    Cache.put(
      key,
      %{
        results: [
          SearchResult.from_api_response(%{"id" => ok, "title" => "Maple Orbit"},
            media_type: :movie
          ),
          SearchResult.from_api_response(%{"id" => r, "title" => "Rust Cathedral"},
            media_type: :movie
          )
        ],
        page: 1,
        total_pages: 1
      },
      ttl: :timer.minutes(30)
    )

    on_exit(fn -> Cache.delete(key) end)

    {:ok, view, _html} = live(conn, ~p"/discover?category=popular")

    assert has_element?(view, "#discover-grid h3", "Maple Orbit")
    refute has_element?(view, "#discover-grid h3", "Rust Cathedral")
  end

  test "the dashboard trending rail is filtered", %{conn: conn} do
    warm_lantern_and_ledger()
    # The dashboard also loads the TV rail on mount.
    warm_trending_cache(:tv_show, [])

    {:ok, view, _html} = live(conn, ~p"/")

    # The rail loads after the connected mount.
    assert wait_until(fn -> render(view) =~ "Lantern Vale" end)
    refute render(view) =~ "Crimson Ledger"
  end

  describe "guest request" do
    test "requesting an allowed title succeeds", %{conn: conn} do
      guest = restricted_user_fixture(%{role: "guest", max_content_age: 12})
      id = unique_provider_id()
      signals(id, :movie, "PG", 8)
      warm_trending_cache(:movie, [%{"id" => id, "title" => "Lantern Vale"}])

      bypass = Bypass.open()
      stub_tmdb_movie(bypass, id, title: "Lantern Vale", certification: "PG")
      previous = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      {:ok, view, _html} = live(log_in_user(conn, guest), ~p"/discover")

      view
      |> element(~s(button[phx-click="request_media"][phx-value-ref="tmdb:#{id}"]))
      |> render_click()

      assert wait_until(fn -> MediaRequests.pending_request_exists?("movie", id) end)
    end
  end

  defp warm_lantern_and_ledger do
    pg = unique_provider_id()
    r = unique_provider_id()
    signals(pg, :movie, "PG", 8)
    signals(r, :movie, "R", 17)

    warm_trending_cache(:movie, [
      %{"id" => pg, "title" => "Lantern Vale"},
      %{"id" => r, "title" => "Crimson Ledger"}
    ])
  end

  defp wait_until(fun, retries \\ 200)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, retries) do
    fun.() || (Process.sleep(10) && wait_until(fun, retries - 1))
  end

  defp signals(id, type, rating, age),
    do:
      warm_remote_signals({:tmdb, id}, type, %RemoteSignals{
        content_rating: rating,
        age: age,
        category: to_string(type)
      })
end
