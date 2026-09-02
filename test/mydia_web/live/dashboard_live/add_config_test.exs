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
