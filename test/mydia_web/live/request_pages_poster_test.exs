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
end
