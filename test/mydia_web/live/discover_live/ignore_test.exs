defmodule MydiaWeb.DiscoverLive.IgnoreTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts
  alias Mydia.Accounts.{DiscoverIgnores, UserPreference}
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.DiscoverLive.Ignores

  defp setup_user(%{conn: conn}) do
    warm_genre_cache(:movie, [])

    user = create_admin_user()
    %{conn: log_in_user(conn, user), user: user}
  end

  defp show_ignored!(user) do
    pref = Accounts.get_user_preference!(user)

    {:ok, _} =
      Accounts.update_preference(pref, %{"preferences" => %{"discover_show_ignored" => true}})
  end

  describe "browsing" do
    setup :setup_user

    test "an ignored title is hidden from the grid on mount", %{conn: conn, user: user} do
      ignored_id = unique_provider_id()
      kept_id = unique_provider_id()
      :ok = DiscoverIgnores.ignore(user, {:tmdb, ignored_id}, :movie)

      warm_trending_cache(:movie, [
        %{"id" => ignored_id, "title" => "Paper Comet"},
        %{"id" => kept_id, "title" => "Velvet Quarry"}
      ])

      {:ok, view, _html} = live(conn, ~p"/discover")

      refute has_element?(view, "#discover-grid h3", "Paper Comet")
      assert has_element?(view, "#discover-grid h3", "Velvet Quarry")
    end

    test "a tv_show ignore does not hide the movie with the same id", %{conn: conn, user: user} do
      id = unique_provider_id()
      :ok = DiscoverIgnores.ignore(user, {:tmdb, id}, :tv_show)

      warm_trending_cache(:movie, [%{"id" => id, "title" => "Paper Comet"}])

      {:ok, view, _html} = live(conn, ~p"/discover")

      assert has_element?(view, "#discover-grid h3", "Paper Comet")
    end

    test "show ignored renders the ignored title with Unignore", %{conn: conn, user: user} do
      id = unique_provider_id()
      :ok = DiscoverIgnores.ignore(user, {:tmdb, id}, :movie)
      show_ignored!(user)

      warm_trending_cache(:movie, [%{"id" => id, "title" => "Paper Comet"}])

      {:ok, view, _html} = live(conn, ~p"/discover")

      assert has_element?(view, "#discover-grid h3", "Paper Comet")
      assert has_element?(view, "#discover-unignore-tmdb-#{id}")
    end

    test "unignored cards carry the ignore button", %{conn: conn} do
      id = unique_provider_id()
      warm_trending_cache(:movie, [%{"id" => id, "title" => "Velvet Quarry"}])

      {:ok, view, _html} = live(conn, ~p"/discover")

      assert has_element?(view, "#discover-ignore-tmdb-#{id}")
    end

    test "ignoring a whole page auto-advances", %{conn: conn, user: user} do
      ignored_id = unique_provider_id()
      visible_id = unique_provider_id()
      :ok = DiscoverIgnores.ignore(user, {:tmdb, ignored_id}, :movie)

      bypass = Bypass.open()
      previous = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        Cache.delete("curated:trending:movie:1")
        Cache.delete("curated:trending:movie:2")

        case previous do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      Bypass.expect(bypass, "GET", "/tmdb/movies/trending", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        {page, id, title} =
          case conn.query_params["page"] do
            "2" -> {2, visible_id, "Velvet Quarry"}
            _ -> {1, ignored_id, "Paper Comet"}
          end

        body = %{
          "page" => page,
          "total_pages" => 2,
          "total_results" => 2,
          "results" => [%{"id" => id, "title" => title}]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      {:ok, view, _html} = live(conn, ~p"/discover")

      wait_until(fn -> has_element?(view, "#discover-grid h3", "Velvet Quarry") end)
      refute has_element?(view, "#discover-grid h3", "Paper Comet")
    end
  end

  describe "ignoring and undoing" do
    setup :setup_user

    setup do
      ignored_id = unique_provider_id()
      kept_id = unique_provider_id()

      warm_trending_cache(:movie, [
        %{"id" => ignored_id, "title" => "Paper Comet"},
        %{"id" => kept_id, "title" => "Velvet Quarry"}
      ])

      %{ignored_id: ignored_id, kept_id: kept_id}
    end

    test "clicking ignore hides the card and shows the toast",
         %{conn: conn, user: user, ignored_id: id} do
      {:ok, view, _html} = live(conn, ~p"/discover")

      view |> element("#discover-ignore-tmdb-#{id}") |> render_click()

      refute has_element?(view, "#discover-grid h3", "Paper Comet")
      assert has_element?(view, "#discover-ignore-toast", "Paper Comet")
      assert MapSet.member?(DiscoverIgnores.keys(user), {:movie, {:tmdb, id}})
    end

    test "Undo restores the card", %{conn: conn, user: user, ignored_id: id} do
      {:ok, view, _html} = live(conn, ~p"/discover")

      view |> element("#discover-ignore-tmdb-#{id}") |> render_click()
      view |> element("#discover-ignore-toast-undo") |> render_click()

      assert has_element?(view, "#discover-grid h3", "Paper Comet")
      refute has_element?(view, "#discover-ignore-toast")
      assert DiscoverIgnores.keys(user) == MapSet.new()
    end

    test "the ignore survives a remount", %{conn: conn, ignored_id: id} do
      {:ok, view, _html} = live(conn, ~p"/discover")
      view |> element("#discover-ignore-tmdb-#{id}") |> render_click()

      {:ok, view, _html} = live(conn, ~p"/discover")

      refute has_element?(view, "#discover-grid h3", "Paper Comet")
    end

    test "the toggle appears only with ignores and persists",
         %{conn: conn, user: user, ignored_id: id} do
      {:ok, view, _html} = live(conn, ~p"/discover")
      refute has_element?(view, "#discover-show-ignored")

      view |> element("#discover-ignore-tmdb-#{id}") |> render_click()
      assert has_element?(view, "label", "Show ignored (1)")

      view |> element("#discover-show-ignored") |> render_click()

      assert UserPreference.discover_show_ignored(Accounts.get_user_preference!(user))

      {:ok, view, _html} = live(conn, ~p"/discover")

      assert has_element?(view, "#discover-show-ignored[checked]")
      assert has_element?(view, "#discover-unignore-tmdb-#{id}")
    end

    test "Unignore from the dimmed card restores it",
         %{conn: conn, user: user, ignored_id: id} do
      :ok = DiscoverIgnores.ignore(user, {:tmdb, id}, :movie)
      show_ignored!(user)

      {:ok, view, _html} = live(conn, ~p"/discover")
      view |> element("#discover-unignore-tmdb-#{id}") |> render_click()

      assert DiscoverIgnores.keys(user) == MapSet.new()
      assert has_element?(view, "#discover-ignore-tmdb-#{id}")
    end

    test "the toggle stays while on, even with no ignores left", %{conn: conn, user: user} do
      show_ignored!(user)

      {:ok, view, _html} = live(conn, ~p"/discover")

      assert has_element?(view, "#discover-show-ignored[checked]")
    end

    test "the toast reads as a whole sentence when the title is unknown", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/discover")

      render_click(view, "ignore_title", %{"ref" => "tmdb:4242", "media_type" => "movie"})

      assert has_element?(view, "#discover-ignore-toast", "Title ignored")
    end

    test "a forged ref changes nothing", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/discover")

      render_click(view, "ignore_title", %{"ref" => "imdb:tt1", "media_type" => "movie"})
      render_click(view, "ignore_title", %{"ref" => "tmdb:1", "media_type" => "episode"})

      assert DiscoverIgnores.keys(user) == MapSet.new()
      assert has_element?(view, "#discover-grid")
    end

    test "a stale toast timer does not clear a newer toast",
         %{conn: conn, ignored_id: first, kept_id: second} do
      {:ok, view, _html} = live(conn, ~p"/discover")

      view |> element("#discover-ignore-tmdb-#{first}") |> render_click()
      view |> element("#discover-ignore-tmdb-#{second}") |> render_click()

      send(view.pid, {:clear_ignore_toast, {:movie, {:tmdb, first}}})

      assert has_element?(view, "#discover-ignore-toast", "Velvet Quarry")

      send(view.pid, {:clear_ignore_toast, {:movie, {:tmdb, second}}})

      refute has_element?(view, "#discover-ignore-toast")
    end

    test "Ignore from the detail modal closes it and hides the card",
         %{conn: conn, user: user, ignored_id: id} do
      # Opening the modal fetches the title's details (with append_to_response,
      # so warm_movie_details_cache/1's key does not cover it). Serve it locally.
      bypass = Bypass.open()
      previous = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      Bypass.stub(bypass, "GET", "/tmdb/movies/#{id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"id" => id, "title" => "Paper Comet"}))
      end)

      {:ok, view, _html} = live(conn, ~p"/discover")

      view
      |> element("div[phx-click='show_details'][phx-value-id='#{id}']")
      |> render_click()

      assert has_element?(view, "#discover-detail-modal[open]")

      view |> element("#detail-ignore") |> render_click()

      refute has_element?(view, "#discover-detail-modal[open]")
      refute has_element?(view, "#discover-grid h3", "Paper Comet")
      assert MapSet.member?(DiscoverIgnores.keys(user), {:movie, {:tmdb, id}})
    end
  end

  describe "search" do
    setup :setup_user

    test "search shows an ignored title with Unignore", %{conn: conn, user: user} do
      id = unique_provider_id()
      :ok = DiscoverIgnores.ignore(user, {:tmdb, id}, :movie)

      warm_movie_search_cache("paper comet", [], [
        %{"id" => id, "title" => "Paper Comet", "release_date" => "2024-01-01"}
      ])

      {:ok, view, _html} = live(conn, ~p"/discover?type=movie&q=paper+comet")

      assert has_element?(view, "#discover-grid h3", "Paper Comet")
      assert has_element?(view, "#discover-unignore-tmdb-#{id}")
    end
  end

  describe "Ignores helpers" do
    test "no user: no ignores, and events are no-ops" do
      socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: nil}}
      socket = Ignores.assign_initial(socket)

      assert socket.assigns.ignored_keys == MapSet.new()

      assert {:noreply, ^socket} =
               Ignores.handle_event(
                 "ignore_title",
                 %{"ref" => "tmdb:1", "media_type" => "movie"},
                 socket
               )
    end

    test "ignored?/3 takes the key set and page media type explicitly" do
      item = %SearchResult{provider: :tmdb, provider_id: 5, media_type: :movie, title: "Velvet"}

      assert Ignores.ignored?(MapSet.new([{:movie, {:tmdb, 5}}]), :movie, item)
      refute Ignores.ignored?(MapSet.new([{:tv_show, {:tmdb, 5}}]), :movie, item)
      refute Ignores.ignored?(MapSet.new(), :movie, item)
    end

    test "ignored_key falls back to the page media type" do
      result =
        %SearchResult{provider: :tmdb, provider_id: 5, media_type: :movie, title: "Velvet Quarry"}
        |> Map.put(:media_type, nil)

      assert Ignores.ignored_key(result, :movie) == {:movie, {:tmdb, 5}}
    end

    test "hiding_ignored? is false with no ignores or with show_ignored on" do
      key = {:movie, {:tmdb, 5}}

      refute Ignores.hiding_ignored?(%{ignored_keys: MapSet.new(), show_ignored: false})
      refute Ignores.hiding_ignored?(%{ignored_keys: MapSet.new([key]), show_ignored: true})
      assert Ignores.hiding_ignored?(%{ignored_keys: MapSet.new([key]), show_ignored: false})
    end
  end

  defp wait_until(fun, retries \\ 200)
  defp wait_until(_fun, 0), do: flunk("condition not met in time")

  defp wait_until(fun, retries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, retries - 1)
    end
  end
end
