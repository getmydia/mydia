defmodule MydiaWeb.RequestAccess.SharedTitleTest do
  @moduledoc """
  Two guests who both want the same title. The duplicate check is global and
  only looks at pending requests, so the second guest is refused rather than
  queued; once the title is approved every guest whose limit allows it sees it.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.RequestAccessCatalog

  alias Mydia.Accounts.Scope
  alias Mydia.Media.MediaRequest
  alias Mydia.MediaRequests
  alias Mydia.Repo

  setup %{conn: conn} do
    world = seed!()
    %{world: world, t: world.titles, cast: cast!(conn)}
  end

  test "a second guest's request is refused as a duplicate", %{t: t, cast: cast} do
    request!(cast.teen, t.pg13_shared)

    view = click_request(cast.adult, t.pg13_shared)

    assert has_element?(view, "#flash-error", "Someone has already requested that title.")
    refute find_request(t.pg13_shared, cast.adult.user.id)
    refute discover_card?(cast.kid, t.pg13_shared)
    assert discover_card?(cast.kid, t.g_movie)
  end

  test "approval makes it visible to every guest whose limit allows it", %{t: t, cast: cast} do
    request = request!(cast.teen, t.pg13_shared)
    approve!(cast.admin, request)

    assert sees_in_library?(cast.adult, t.pg13_shared)
    assert sees_in_library?(cast.teen, t.pg13_shared)
    refute sees_in_library?(cast.kid, t.pg13_shared)
  end

  test "cancelling frees the title for another guest", %{t: t, cast: cast} do
    request = request!(cast.teen, t.pg13_shared)
    assert {:ok, _} = MediaRequests.cancel_request(Scope.for_user(cast.teen.user), request)

    assert request!(cast.adult, t.pg13_shared).status == "pending"
  end

  test "an admin adding the title directly approves the pending request", %{t: t, cast: cast} do
    request = request!(cast.adult, t.pg13_shared)

    {:ok, discover, _html} = live(cast.admin.conn, ~p"/discover")

    discover
    |> element(
      ~s(button[phx-click="add_to_library"][phx-value-ref="tmdb:#{t.pg13_shared.tmdb_id}"])
    )
    |> render_click()

    assert wait_until(fn -> media_item_for(t.pg13_shared) end)
    item = media_item_for(t.pg13_shared)

    assert wait_until(fn -> Repo.get!(MediaRequest, request.id).status == "approved" end)
    approved = Repo.get!(MediaRequest, request.id)
    assert approved.media_item_id == item.id
    assert approved.approved_by_id == cast.admin.user.id
  end
end
