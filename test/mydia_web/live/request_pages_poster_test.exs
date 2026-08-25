defmodule MydiaWeb.RequestPagesPosterTest do
  @moduledoc """
  Both request pages show a poster. Rows created before the poster_path column
  existed fill in from the provider on first view.
  """

  # async: false: setup_metadata_stub swaps the global Provider.Registry, and
  # connected LiveView mounts run outside the test process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataStub

  alias Mydia.Media.MediaRequest
  alias Mydia.MediaRequests
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo

  setup :setup_metadata_stub

  setup do
    guest = create_test_user(%{role: "guest"})
    admin = create_admin_user()

    %{guest: guest, admin: admin}
  end

  defp request_fixture(user, attrs \\ %{}) do
    base = %{
      media_type: "movie",
      title: "Stub Movie",
      year: 1999,
      tmdb_id: MetadataStubProvider.movie_tmdb_id(),
      requester_id: user.id
    }

    {:ok, request} = MediaRequests.create_request(Map.merge(base, attrs))
    request
  end

  test "the admin page renders a stored poster", %{conn: conn, admin: admin, guest: guest} do
    request = request_fixture(guest, %{poster_path: "/stub-movie-poster.jpg"})

    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/admin/requests")

    assert has_element?(
             view,
             ~s(#request-#{request.id} img[src="https://image.tmdb.org/t/p/w185/stub-movie-poster.jpg"])
           )
  end

  test "My Requests renders a stored poster", %{conn: conn, guest: guest} do
    request = request_fixture(guest, %{poster_path: "/stub-movie-poster.jpg"})

    {:ok, view, _html} = live(log_in_user(conn, guest), ~p"/requests")

    assert has_element?(
             view,
             ~s(#request-#{request.id} img[src="https://image.tmdb.org/t/p/w185/stub-movie-poster.jpg"])
           )
  end

  test "a request with no stored poster backfills on first view", %{
    conn: conn,
    admin: admin,
    guest: guest
  } do
    request = request_fixture(guest)
    assert is_nil(request.poster_path)

    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/admin/requests")

    # render/1 round-trips through the LiveView process, so the backfill
    # message queued during mount has been handled by the time it returns.
    render(view)

    assert Repo.get!(MediaRequest, request.id).poster_path == "/stub-movie-poster.jpg"

    assert has_element?(
             view,
             ~s(#request-#{request.id} img[src="https://image.tmdb.org/t/p/w185/stub-movie-poster.jpg"])
           )
  end

  test "an imdb-only request renders the placeholder and no click target", %{
    conn: conn,
    admin: admin,
    guest: guest
  } do
    request = request_fixture(guest, %{tmdb_id: nil, imdb_id: "tt0137523"})

    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/admin/requests")
    render(view)

    assert has_element?(view, ~s(#request-#{request.id} img[src="/images/no-poster.svg"]))
    refute has_element?(view, ~s(#request-#{request.id} button[phx-click="show_details"]))
  end

  test "a permanently-unresolvable request is attempted once, not retried in a loop", %{
    conn: conn,
    admin: admin,
    guest: guest
  } do
    # missing_id/0 is detailable (it is a tmdb_id) but its fetch always
    # errors, which is exactly the row shape that used to loop: mount/3's
    # load_requests/1 and the handle_params/3 that LiveView calls right after
    # it both reach maybe_backfill_posters/2, and needs_poster?/1 stays true
    # forever for a row whose fetch can never succeed.
    request = request_fixture(guest, %{tmdb_id: MetadataStubProvider.missing_id()})
    assert is_nil(request.poster_path)

    MetadataStubProvider.reset_fetch_by_id_count!()

    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/admin/requests")

    # render/1 round-trips through the LiveView process, so the one backfill
    # message queued during mount has been handled by the time it returns. If
    # handle_info re-sent itself, the process would be mid-loop right now.
    render(view)

    assert Repo.get!(MediaRequest, request.id).poster_path == nil

    assert MetadataStubProvider.fetch_by_id_count(to_string(MetadataStubProvider.missing_id())) ==
             1

    # The LiveView process must still be responsive to ordinary events: a
    # busy resend loop would starve normal message handling. Switching tabs
    # re-runs load_requests/1 (and therefore maybe_backfill_posters/2) again,
    # so this also proves an already-attempted id is not retried on a second
    # pass within the same connected session.
    view
    |> element(~s(button[phx-click="filter"][phx-value-status="all"]))
    |> render_click()

    assert has_element?(view, ~s(#request-#{request.id}))

    assert MetadataStubProvider.fetch_by_id_count(to_string(MetadataStubProvider.missing_id())) ==
             1
  end
end
