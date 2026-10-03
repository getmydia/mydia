defmodule MydiaWeb.RequestAccess.RejectAndUnratedTest do
  @moduledoc """
  Rejections reach only the requester, and a title with no rating is hidden
  from every age-limited account even after an admin approves it for someone
  who has no limit.
  """

  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.RequestAccessCatalog

  setup %{conn: conn} do
    world = seed!()
    %{world: world, t: world.titles, cast: cast!(conn)}
  end

  test "a rejection reason reaches only the requester", %{t: t, cast: cast} do
    request = request!(cast.teen, t.pg13_movie)
    other = request!(cast.adult, t.r_movie)

    rejected = reject!(cast.admin, request, "Not this month, sorry")

    assert is_nil(rejected.media_item_id)
    refute media_item_for(t.pg13_movie)

    teen_view = my_requests_view(cast.teen)
    assert has_element?(teen_view, "#request-#{request.id}", "Not this month, sorry")

    adult_view = my_requests_view(cast.adult)
    refute has_element?(adult_view, "#request-#{request.id}")
    assert has_element?(adult_view, "#request-#{other.id}")
  end

  test "an unrated title stays hidden from age-limited guests after approval",
       %{t: t, cast: cast, world: world} do
    forge_request(cast.kid, t.unrated_movie)
    forge_request(cast.teen, t.unrated_movie)
    assert {:error, :restricted} = create_as(cast.kid, t.unrated_movie, world)

    request = request!(cast.adult, t.unrated_movie)
    approve!(cast.admin, request)

    item = media_item_for(t.unrated_movie)
    assert is_nil(item.content_rating_age)

    assert sees_in_library?(cast.adult, t.unrated_movie)
    refute sees_in_library?(cast.teen, t.unrated_movie)
    refute sees_in_library?(cast.kid, t.unrated_movie)

    # Paired positive on the same page for the age-limited guests.
    request!(cast.kid, t.g_movie) |> then(&approve!(cast.admin, &1))
    assert sees_in_library?(cast.kid, t.g_movie)
    assert sees_in_library?(cast.teen, t.g_movie)
  end

  test "a guest can request a title again after a rejection", %{t: t, cast: cast} do
    request = request!(cast.teen, t.pg13_movie)
    reject!(cast.admin, request, "Ask again later")

    {:ok, view, _html} = live(cast.teen.conn, ~p"/discover")

    view
    |> element(
      ~s(button[phx-click="request_media"][phx-value-ref="tmdb:#{t.pg13_movie.tmdb_id}"])
    )
    |> render_click()

    assert wait_until(fn ->
             Mydia.Repo.get_by(Mydia.Media.MediaRequest,
               tmdb_id: t.pg13_movie.tmdb_id,
               status: "pending"
             )
           end)
  end
end
