defmodule MydiaWeb.DashboardLive.RequestStatusMapTest do
  @moduledoc """
  Regression: `load_dashboard_data/1` called `MediaRequestHelpers.request_status_map/0`
  unconditionally, issuing two unfiltered `list_requests/1` scans on every
  mount even though the result only ever drives the Request button, which
  `Accounts.Authorization.can_submit_request?/1` gates to guests only (#464).
  A non-guest must not pay for a query whose result they can never act on.
  """

  # async: false — the Postgres non-shared sandbox hides the request row from
  # the LiveView mount process otherwise (mirrors stat_tiles_test.exs, which
  # mounts the same LiveView).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MetadataCacheHelpers
  import MydiaWeb.AuthHelpers

  setup do
    # DashboardLive.Index unconditionally loads both trending rails on
    # connected mount (#530).
    warm_trending_cache(:movie, [])
    warm_trending_cache(:tv_show, [])
    :ok
  end

  defp create_pending_request(tmdb_id) do
    requester = user_fixture(%{role: "guest"})

    {:ok, request} =
      Mydia.MediaRequests.create_request(%{
        media_type: "movie",
        title: "A Placeholder Title",
        tmdb_id: tmdb_id,
        requester_id: requester.id
      })

    request
  end

  test "a non-guest viewer gets an empty request_status_map even with outstanding requests", %{
    conn: conn
  } do
    tmdb_id = System.unique_integer([:positive])
    create_pending_request(tmdb_id)

    conn = log_in_user(conn, user_fixture(%{role: "user"}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert :sys.get_state(view.pid).socket.assigns.request_status_map == %{}
  end

  test "a guest viewer sees the outstanding request in request_status_map", %{conn: conn} do
    tmdb_id = System.unique_integer([:positive])
    create_pending_request(tmdb_id)

    conn = log_in_user(conn, user_fixture(%{role: "guest"}))
    {:ok, view, _html} = live(conn, ~p"/")

    assert :sys.get_state(view.pid).socket.assigns.request_status_map == %{tmdb_id => "pending"}
  end
end
