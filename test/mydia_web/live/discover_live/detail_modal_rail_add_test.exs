defmodule MydiaWeb.DiscoverLive.DetailModalRailAddTest do
  @moduledoc """
  Adding or requesting a title the dialog was swapped onto through its own
  "More like this" rail (#1448).

  The swap fetches the new title's recommendations, which replace the rail it
  was opened from. From then on the open title is in no host list, so the
  post-add refresh of the dialog's snapshot found nothing and the header kept
  offering "Add to Library" for a title that was already in the library.

  Every relay route is served by one Bypass, pointed at with the global relay
  URL, so this file cannot run async.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import Mydia.RelayStubHelpers
  import Mydia.SettingsFixtures

  alias Mydia.Media.MediaItem
  alias Mydia.Media.MediaRequest
  alias Mydia.Repo

  setup do
    warm_genre_cache(:movie, [])
    warm_genre_cache(:tv_show, [])
    library_path_fixture(%{type: "movies"})

    bypass = point_relay_at_bypass()
    first_id = unique_provider_id()
    swapped_id = unique_provider_id()
    onward_id = unique_provider_id()

    warm_trending_cache(:movie, [%{"id" => first_id, "title" => "Lantern Ward"}])

    stub_movie(bypass, first_id, "Lantern Ward", [rec(swapped_id, "Glass Orchard")])
    stub_movie(bypass, swapped_id, "Glass Orchard", [rec(onward_id, "Copper Tide")])
    stub_movie(bypass, onward_id, "Copper Tide", [])

    %{first_id: first_id, swapped_id: swapped_id, onward_id: onward_id}
  end

  test "the header shows Go to Movie after adding a title opened from the rail", ctx do
    {:ok, view, _html} = live(log_in_user(ctx.conn, create_admin_user()), ~p"/discover")

    swap_to_rail_title(view, ctx)

    view
    |> element("#trending-detail-modal-actions button[phx-click='add_to_library']")
    |> render_click()

    # The add runs in a handle_info queued by the click; a render waits for it.
    render(view)

    assert %MediaItem{} = Repo.get_by(MediaItem, tmdb_id: ctx.swapped_id, type: "movie")

    refute has_element?(
             view,
             "#trending-detail-modal-actions button[phx-click='add_to_library']"
           )

    assert has_element?(view, "#trending-detail-modal-actions a", "Go to Movie")
  end

  test "the header shows Requested after a guest requests a title opened from the rail", ctx do
    {:ok, view, _html} =
      live(log_in_user(ctx.conn, user_fixture(%{role: "guest"})), ~p"/discover")

    swap_to_rail_title(view, ctx)

    view
    |> element("#trending-detail-modal-actions button[phx-click='request_media']")
    |> render_click()

    render(view)

    assert %MediaRequest{} = Repo.get_by(MediaRequest, tmdb_id: ctx.swapped_id)

    assert has_element?(
             view,
             "#trending-detail-modal-actions button[phx-click='request_media'][disabled]",
             "Requested"
           )
  end

  # Opens the first title, then the rail title, and waits until the swapped
  # title's own recommendations have replaced the rail it was picked from.
  defp swap_to_rail_title(view, ctx) do
    view
    |> element("div[phx-click='show_details'][phx-value-id='#{ctx.first_id}']")
    |> render_click()

    wait_until(fn ->
      has_element?(view, "#discover-recommendations-rail-item-#{ctx.swapped_id}")
    end)

    view
    |> element(
      "#discover-recommendations-rail div[phx-click='show_details'][phx-value-id='#{ctx.swapped_id}']"
    )
    |> render_click()

    wait_until(fn ->
      has_element?(view, "#discover-recommendations-rail-item-#{ctx.onward_id}")
    end)

    refute has_element?(view, "#discover-recommendations-rail-item-#{ctx.swapped_id}")
    assert has_element?(view, "#discover-detail-modal h2", "Glass Orchard")
  end

  defp rec(id, title), do: %{"id" => id, "title" => title, "release_date" => "2022-06-01"}

  # Serves both the detail fetch and the recommendations fetch, which share the
  # movie route.
  defp stub_movie(bypass, id, title, recommendations) do
    Bypass.stub(bypass, "GET", "/tmdb/movies/#{id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "id" => id,
          "title" => title,
          "release_date" => "2021-04-02",
          "overview" => "An invented film.",
          "genres" => [],
          "belongs_to_collection" => nil,
          "credits" => %{"cast" => [], "crew" => []},
          "videos" => %{"results" => []},
          "recommendations" => %{
            "page" => 1,
            "results" => recommendations,
            "total_pages" => 1,
            "total_results" => length(recommendations)
          }
        })
      )
    end)
  end

  # The detail fetch runs in a handle_info and queues the recommendations fetch
  # behind it, neither tracked by render_async/2, so polling is what proves the
  # sequence settled.
  defp wait_until(fun, retries \\ 200)
  defp wait_until(_fun, 0), do: flunk("condition was not met in time")

  defp wait_until(fun, retries) do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      wait_until(fun, retries - 1)
    end
  end
end
