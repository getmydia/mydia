defmodule MydiaWeb.DiscoverLive.IgnoreTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataCacheHelpers

  alias Mydia.Accounts
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
      :ok = Accounts.ignore_discover_title(user, {:tmdb, ignored_id}, :movie)

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
      :ok = Accounts.ignore_discover_title(user, {:tmdb, id}, :tv_show)

      warm_trending_cache(:movie, [%{"id" => id, "title" => "Paper Comet"}])

      {:ok, view, _html} = live(conn, ~p"/discover")

      assert has_element?(view, "#discover-grid h3", "Paper Comet")
    end

    test "show ignored renders the ignored title with Unignore", %{conn: conn, user: user} do
      id = unique_provider_id()
      :ok = Accounts.ignore_discover_title(user, {:tmdb, id}, :movie)
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
      :ok = Accounts.ignore_discover_title(user, {:tmdb, ignored_id}, :movie)

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

  describe "Ignores helpers" do
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
