defmodule MydiaWeb.DashboardLive.AddConfigTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.SettingsFixtures

  setup %{conn: conn} do
    # DashboardLive.Index unconditionally loads both trending rails on
    # connected mount (#530); warm the cache so tests don't hit the network.
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])

    user = user_fixture(%{role: "admin"})
    library = library_path_fixture(%{type: :movies, monitored: true})
    %{conn: log_in_user(conn, user), user: user, library: library}
  end

  test "open_add_config assigns the dialog for a movie", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "open_add_config", %{
      "tmdb_id" => "551",
      "media_type" => "movie",
      "title" => "The Kestrel Protocol"
    })

    assert has_element?(view, "#add-config-modal[open]")
    assert render(view) =~ "Configure Before Adding"
    assert render(view) =~ "The Kestrel Protocol"
  end

  test "close_add_config closes the dialog", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "open_add_config", %{
      "tmdb_id" => "551",
      "media_type" => "movie",
      "title" => "The Kestrel Protocol"
    })

    render_hook(view, "close_add_config", %{})

    refute has_element?(view, "#add-config-modal[open]")
  end

  test "submit_add_config with a forged library flashes and adds nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "open_add_config", %{
      "tmdb_id" => "551",
      "media_type" => "movie",
      "title" => "The Kestrel Protocol"
    })

    html =
      render_hook(view, "submit_add_config", %{
        "config" => %{
          "library_path_id" => "not-a-real-id",
          "monitored" => "true",
          "search_on_add" => "false"
        }
      })

    assert html =~ "That library is no longer available"
    refute has_element?(view, "#add-config-modal[open]")
  end

  # The add completes in a handle_info the submit's render_hook round trip does
  # not wait on: it fetches metadata over Bypass before creating the row (see
  # discover_live/config_modal_test.exs). Without stubbing this, the fetch
  # reaches relay.mydia.dev for real and RelayGuard fails the whole suite at
  # exit, so this test needs the same Bypass swap even though it only asserts
  # on the dialog closing synchronously.
  test "submit_add_config with a valid library closes the dialog", %{
    conn: conn,
    library: library
  } do
    provider_id = "551"

    bypass = Bypass.open()
    previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous_metadata_relay_url do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    Bypass.expect(bypass, "GET", "/tmdb/movies/#{provider_id}", fn conn ->
      body = %{
        "id" => provider_id,
        "title" => "The Kestrel Protocol",
        "release_date" => "2024-05-01",
        "belongs_to_collection" => nil
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "open_add_config", %{
      "tmdb_id" => provider_id,
      "media_type" => "movie",
      "title" => "The Kestrel Protocol"
    })

    render_hook(view, "submit_add_config", %{
      "config" => %{
        "library_path_id" => to_string(library.id),
        "monitored" => "true",
        "search_on_add" => "false"
      }
    })

    refute has_element?(view, "#add-config-modal[open]")

    wait_until_media_item(provider_id)
  end

  # The plain (non-Configure) "Add to Library" button on Dashboard sends this
  # event directly, bypassing submit_add_config entirely. Mirrors
  # add_config_host_test.exs's identical regression test: Mydia.RelayGuard
  # blocks the unstubbed relay call in this test environment, so an
  # unauthorized add would create no media item even with the gate deleted,
  # and the absence of a media item would prove nothing about authorization.
  # Bypass.stub (not expect) keeps the assertion honest either way: a
  # correctly-gated add must never reach this endpoint, but the test must
  # still pass if it somehow did.
  test "a guest cannot add_to_library even with a stubbed metadata endpoint", %{conn: conn} do
    guest = user_fixture(%{role: "guest"})
    conn = log_in_user(conn, guest)

    provider_id = to_string(unique_provider_id())

    bypass = Bypass.open()
    previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous_metadata_relay_url do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    Bypass.stub(bypass, "GET", "/tmdb/movies/#{provider_id}", fn conn ->
      body = %{
        "id" => provider_id,
        "title" => "The Kestrel Protocol",
        "release_date" => "2024-05-01",
        "belongs_to_collection" => nil
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    {:ok, view, _html} = live(conn, ~p"/")

    render_hook(view, "add_to_library", %{
      "tmdb_id" => provider_id,
      "media_type" => "movie"
    })

    # A correctly-gated event returns synchronously with no handle_info
    # dispatched. Give an incorrectly-gated add (which does dispatch one, and
    # would round-trip through the local Bypass server) time to land before
    # asserting nothing was created.
    Process.sleep(200)

    assert Mydia.Media.get_media_item_by_tmdb(provider_id) == nil
  end

  # Configure is also reachable from a caret inside the detail modal's own
  # header actions (TrendingDetailModal renders its default action set on
  # Dashboard; there is no :actions slot override and no :rail slot here).
  # DashboardLive's own open_add_config handler, unlike close_details, never
  # clears @selected_item, so the detail modal stays open underneath. Without
  # TrendingDetailModal's config_open guard, one Escape press would fire both
  # close_add_config and close_details and silently close the detail view the
  # user never asked to leave. Mirrors
  # discover_live/config_modal_test.exs's identical regression test for
  # Discover, which already guards this correctly.
  describe "Escape while the detail modal is also open" do
    setup do
      provider_id = unique_provider_id()

      # The module setup above already warmed "trending_movies" to []
      # through the real fetch-through-cache path (Mydia.Metadata.Cache is
      # ETS-backed and process-independent). A second warm_trending_cache/2
      # call for the same media_type would just read that cached empty list
      # back instead of hitting this describe's own Bypass stub, so the
      # stale entry has to be cleared first.
      Mydia.Metadata.Cache.delete("trending_movies")
      Mydia.Metadata.Cache.delete("curated:trending:movie:1")

      warm_trending_cache(:movie, [
        %{"id" => provider_id, "title" => "The Kestrel Protocol", "release_date" => "2024-05-01"}
      ])

      bypass = Bypass.open()
      previous_metadata_relay_url = Application.get_env(:mydia, :metadata_relay_url)
      Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

      on_exit(fn ->
        case previous_metadata_relay_url do
          nil -> Application.delete_env(:mydia, :metadata_relay_url)
          value -> Application.put_env(:mydia, :metadata_relay_url, value)
        end
      end)

      # The detail modal's own metadata fetch (fetch_detail_metadata ->
      # Metadata.fetch_by_id) is uncached, matching config_modal_test.exs's
      # identical setup for Discover.
      Bypass.expect(bypass, "GET", "/tmdb/movies/#{provider_id}", fn conn ->
        body = %{
          "id" => provider_id,
          "title" => "The Kestrel Protocol",
          "release_date" => "2024-05-01",
          "belongs_to_collection" => nil
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      %{provider_id: provider_id}
    end

    test "pressing Escape while Configure is open over the detail modal closes only Configure",
         %{conn: conn, provider_id: provider_id} do
      {:ok, view, _html} = live(conn, ~p"/")

      view
      |> element("div[phx-click='show_details'][phx-value-id='#{provider_id}']")
      |> render_click()

      assert has_element?(view, "#trending-detail-modal[open]")

      render_async(view, 5000)

      # Scoped to the modal: the trending card underneath also renders its
      # own "Add to Library" split button with the same data-test caret.
      caret = "#trending-detail-modal [data-test='add-config-caret']"

      assert has_element?(view, caret)

      view |> element(caret) |> render_click()

      assert has_element?(view, "#add-config-modal[open]")

      # The detail modal's own Escape binding must be suppressed while
      # Configure is open, or a real Escape press would fire both handlers.
      refute has_element?(view, "#trending-detail-modal[phx-window-keydown]")

      view |> element("#add-config-modal") |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "#add-config-modal[open]")
      assert has_element?(view, "#trending-detail-modal[open]")
    end
  end

  # Guards the test above: the add finishes in a handle_info this test's
  # render_hook does not wait on. Without polling, on_exit could tear down
  # Bypass and revert metadata_relay_url while the fetch is still in flight.
  defp wait_until_media_item(provider_id, retries \\ 200)

  defp wait_until_media_item(provider_id, 0) do
    flunk("media item for provider_id=#{provider_id} was not created in time")
  end

  defp wait_until_media_item(provider_id, retries) do
    case Mydia.Media.get_media_item_by_tmdb(provider_id) do
      nil ->
        Process.sleep(10)
        wait_until_media_item(provider_id, retries - 1)

      media_item ->
        media_item
    end
  end
end
