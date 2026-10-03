defmodule MydiaWeb.DiscoverLive.RestrictedPreviewTest do
  @moduledoc """
  A card can pass the list filter on cheap signals while the detail metadata
  carries a stricter rating. The preview must then show the rating and offer
  no Request button.
  """

  use MydiaWeb.ConnCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.RelayStubs
  import Phoenix.LiveViewTest

  alias Mydia.Media.RemoteSignals

  setup %{conn: conn} do
    warm_genre_cache(:movie, [])

    bypass = Bypass.open()
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    guest = restricted_user_fixture(%{role: "guest", max_content_age: 12})
    %{conn: log_in_user(conn, guest), bypass: bypass}
  end

  defp wait_until(fun, retries \\ 200)
  defp wait_until(_fun, 0), do: false

  defp wait_until(fun, retries) do
    fun.() || (Process.sleep(10) && wait_until(fun, retries - 1))
  end

  test "a title rated over the limit shows the rating and no Request button", %{
    conn: conn,
    bypass: bypass
  } do
    id = unique_provider_id()

    warm_remote_signals({:tmdb, id}, :movie, %RemoteSignals{
      content_rating: "PG",
      age: 8,
      category: "movie"
    })

    stub_tmdb_movie(bypass, id, title: "Dune Lantern", certification: "R")
    warm_trending_cache(:movie, [%{"id" => id, "title" => "Dune Lantern"}])

    {:ok, view, _html} = live(conn, ~p"/discover")

    view
    |> element("div[phx-click='show_details'][phx-value-id='#{id}']")
    |> render_click()

    assert wait_until(fn -> has_element?(view, "#trending-detail-restricted") end)
    assert has_element?(view, "#trending-detail-content-rating", "R")
    refute has_element?(view, "#discover-detail-modal button[phx-click='request_media']")
  end
end
