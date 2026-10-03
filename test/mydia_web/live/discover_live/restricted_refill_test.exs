defmodule MydiaWeb.DiscoverLive.RestrictedRefillTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import Phoenix.LiveViewTest

  alias Mydia.Accounts.Scope
  alias Mydia.Media.RemoteSignals
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.DiscoverLive.Index

  setup do
    scope = Scope.for_user(restricted_user_fixture(%{max_content_age: 12}))
    %{scope: scope}
  end

  test "a page the restriction empties advances even with hide_owned off", %{scope: scope} do
    blocked = unique_provider_id()
    allowed = unique_provider_id()
    signals(blocked, "R", 17)
    signals(allowed, "PG", 8)
    seed_curated_page(1, 2, [curated_result(blocked, "Ash Verdict")])
    seed_curated_page(2, 2, [curated_result(allowed, "Kite Harbor")])

    socket = curated_socket(%{current_scope: scope, hide_owned: false})

    {:noreply, socket} = Index.handle_info(:load_data, socket)
    assert_received {:load_page, 2, 1, 20}

    {:noreply, socket} = Index.handle_info({:load_page, 2, 1, 20}, socket)
    assert [%{title: "Kite Harbor"}] = socket.assigns.visible_items
  end

  test "a restricted scope may advance up to eight pages", %{scope: scope} do
    blocked = unique_provider_id()
    signals(blocked, "R", 17)

    for page <- 1..9,
        do: seed_curated_page(page, 12, [curated_result(blocked, "Grey Signal #{page}")])

    socket = curated_socket(%{current_scope: scope, hide_owned: false})
    {:noreply, socket} = Index.handle_info(:load_data, socket)

    socket =
      Enum.reduce(2..9, socket, fn page, socket ->
        assert_received {:load_page, ^page, advances, 20}
        {:noreply, socket} = Index.handle_info({:load_page, page, advances, 20}, socket)
        socket
      end)

    refute_received {:load_page, _, _, _}
    assert socket.assigns.has_more == true
  end

  test "an unrestricted scope with hide_owned off never advances" do
    seed_curated_page(1, 2, [curated_result(unique_provider_id(), "Open Field")])
    socket = curated_socket(%{current_scope: Scope.unrestricted(), hide_owned: false})

    {:noreply, _socket} = Index.handle_info(:load_data, socket)
    refute_received {:load_page, _, _, _}
  end

  test "the empty state for a restricted account names neither category nor age", %{conn: conn} do
    warm_genre_cache(:movie, [])
    blocked = unique_provider_id()
    signals(blocked, "R", 17)
    warm_trending_cache(:movie, [%{"id" => blocked, "title" => "Ash Verdict"}])

    conn = log_in_user(conn, restricted_user_fixture(%{max_content_age: 12}))
    {:ok, view, _html} = live(conn, ~p"/discover")

    assert has_element?(view, "#discover-restricted-empty")

    assert view |> element("#discover-restricted-empty") |> render() =~
             "Nothing here is available for your account."
  end

  test "a type with no allowed category shows the empty state without fetching", %{conn: conn} do
    warm_genre_cache(:tv_show, [])
    conn = log_in_user(conn, restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))

    {:ok, view, _html} = live(conn, ~p"/discover?type=tv_show&category=discover")

    assert has_element?(view, "#discover-restricted-empty")
  end

  test "a cartoon-only account hints Animation to TMDB discover", %{conn: conn} do
    warm_genre_cache(:movie, [])

    bypass = Bypass.open()
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      Cache.clear()

      case previous do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    test_pid = self()

    Bypass.expect(bypass, "GET", "/tmdb/movies/discover", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      send(test_pid, {:discover_params, conn.query_params})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"results" => [], "total_pages" => 1}))
    end)

    conn = log_in_user(conn, restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]}))
    {:ok, _view, _html} = live(conn, ~p"/discover?category=discover")

    assert_receive {:discover_params, params}, 2_000
    assert params["with_genres"] == "16"
  end

  defp signals(id, rating, age),
    do:
      warm_remote_signals({:tmdb, id}, :movie, %RemoteSignals{
        content_rating: rating,
        age: age,
        category: "movie"
      })

  defp curated_socket(overrides) do
    base = %{
      __changed__: %{},
      flash: %{},
      current_scope: Scope.unrestricted(),
      media_type: :movie,
      search_mode: false,
      search_query: "",
      category: :trending,
      page: 1,
      items: [],
      visible_items: [],
      has_more: true,
      hide_owned: true,
      library_status_map: %{},
      request_status_map: %{},
      loading_more: false
    }

    %Phoenix.LiveView.Socket{assigns: Map.merge(base, overrides)}
  end

  defp seed_curated_page(page, total_pages, results) do
    key = "curated:trending:movie:#{page}"

    Cache.put(key, %{results: results, page: page, total_pages: total_pages},
      ttl: :timer.minutes(30)
    )

    on_exit(fn -> Cache.delete(key) end)
  end

  defp curated_result(id, title) do
    SearchResult.from_api_response(%{"id" => id, "title" => title}, media_type: :movie)
  end
end
