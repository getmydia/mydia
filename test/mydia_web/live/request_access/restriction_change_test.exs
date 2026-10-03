defmodule MydiaWeb.RequestAccess.RestrictionChangeTest do
  @moduledoc """
  An admin changes a guest's age limit around an approval. The restriction is
  checked when a request is filed, not when it is approved, so approval of an
  older request still goes through; what matters is that the result stays out
  of the guest's reach until their limit allows it.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.RequestAccessCatalog

  alias Mydia.Accounts

  setup %{conn: conn} do
    world = seed!()
    %{world: world, t: world.titles, cast: cast!(conn)}
  end

  defp set_limit!(who, age) do
    {:ok, _} = Accounts.upsert_access_restriction(who.user, %{max_content_age: age})
  end

  test "a title approved after the limit was lowered stays hidden", %{t: t, cast: cast} do
    request = request!(cast.teen, t.pg13_movie)
    set_limit!(cast.teen, 7)
    approved = approve!(cast.admin, request)

    refute sees_in_library?(cast.teen, t.pg13_movie)
    assert sees_in_library?(cast.adult, t.pg13_movie)

    view = my_requests_view(cast.teen)
    # The guest's own history keeps the row ...
    assert has_element?(view, "#request-#{approved.id}")
    # ... but must not offer a link into a title they cannot open.
    refute has_element?(
             view,
             ~s(#request-#{approved.id} a[href="/media/#{approved.media_item_id}"])
           )
  end

  test "raising the limit back reveals the title", %{t: t, cast: cast} do
    request = request!(cast.teen, t.pg13_movie)
    set_limit!(cast.teen, 7)
    approved = approve!(cast.admin, request)
    refute sees_in_library?(cast.teen, t.pg13_movie)

    set_limit!(cast.teen, 14)

    assert sees_in_library?(cast.teen, t.pg13_movie)

    assert has_element?(
             my_requests_view(cast.teen),
             ~s(#request-#{approved.id} a[href="/media/#{approved.media_item_id}"])
           )
  end

  test "a pending request survives a lowered limit and can still be approved",
       %{t: t, cast: cast, world: world} do
    request = request!(cast.teen, t.pg13_movie)
    set_limit!(cast.teen, 7)

    # New requests at the old rating are refused now ...
    assert {:error, :restricted} = create_as(cast.teen, t.pg13_shared, world)
    # ... the older one stays queued and approvable (checked at file time only).
    {:ok, queue, _html} = live(cast.admin.conn, ~p"/admin/requests")
    assert has_element?(queue, "#request-#{request.id}")
    assert approve!(cast.admin, request).status == "approved"
  end
end
