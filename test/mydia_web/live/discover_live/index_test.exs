defmodule MydiaWeb.DiscoverLive.IndexTest do
  @moduledoc """
  Covers the media-type segmented control (`#discover-media-type`, event
  `switch_media_type`, param `type`).

  This call site has no other rendering test: add_config_flow_test.exs and
  friends in this directory only exercise handle_event/3 directly or unit
  functions, and grid_density_test.exs (in the parent directory) covers the
  density toggle, not the media-type one. A wrong param name or a
  handle_event clause that stopped matching would be invisible to the rest
  of the suite.
  """

  # async: false — the Postgres non-shared sandbox hides these rows from the
  # LiveView mount process otherwise (mirrors grid_density_test.exs, which
  # mounts the same LiveView).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import MydiaWeb.AuthHelpers

  setup %{conn: conn} do
    # DiscoverLive.Index unconditionally loads the movie genre list and its
    # default (trending) category on connected mount (#530). Warming trending
    # for both media types keeps the media-type click from falling through to
    # the live relay once @media_type flips to :tv_show. The genre list must
    # be non-empty: mount only skips a reload when `@genres != []`, so an
    # empty warmed list still re-fetches (this time for :tv_show, unwarmed)
    # the moment the media type switches.
    warm_genre_cache(:movie, [%{"id" => 28, "name" => "Action"}])
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])

    user = admin_user_fixture()
    %{conn: log_in_user(conn, user)}
  end

  test "a reversed year range is swapped", %{conn: conn} do
    # The range fetch is not warmed, so stub the relay rather than let the
    # connected mount reach the network.
    bypass = Bypass.open()
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    Bypass.stub(bypass, "GET", "/tmdb/movies/discover", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"results" => [], "total_pages" => 1}))
    end)

    {:ok, view, _html} =
      live(conn, ~p"/discover?category=discover&year_from=2010&year_to=2000")

    assert has_element?(view, "#discover-year-from option[value='2000'][selected]")
    assert has_element?(view, "#discover-year-to option[value='2010'][selected]")
  end

  test "the media-type control defaults to Movies selected", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/discover")

    assert html =~ ~s(id="discover-media-type")

    assert has_element?(
             view,
             "#discover-media-type button[phx-value-type='movie'][aria-pressed='true']"
           )

    assert has_element?(
             view,
             "#discover-media-type button[phx-value-type='tv_show'][aria-pressed='false']"
           )
  end

  test "choosing TV Shows dispatches switch_media_type and moves the selection", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/discover")

    view
    |> element("#discover-media-type button[phx-value-type='tv_show']")
    |> render_click()

    # switch_media_type push_patches to ?type=tv_show rather than assigning
    # directly, so a moved selection also proves handle_params re-derived
    # @media_type from the query string.
    assert_patch(view, ~p"/discover?type=tv_show")

    assert has_element?(
             view,
             "#discover-media-type button[phx-value-type='tv_show'][aria-pressed='true']"
           )

    assert has_element?(
             view,
             "#discover-media-type button[phx-value-type='movie'][aria-pressed='false']"
           )
  end
end
