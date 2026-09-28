defmodule MydiaWeb.RequestDetailPopupTest do
  @moduledoc """
  Clicking a request title opens the same detail popup Discovery uses.
  Approving from inside it must close the popup as the approve dialog opens:
  TrendingDetailModal binds phx-window-keydown for Escape, which is not scoped
  by visual stacking, so two open dialogs would share one Escape press.
  """

  # async: false: setup_metadata_stub swaps the global Provider.Registry, and
  # connected LiveView mounts run outside the test process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataStub

  alias Mydia.Accounts.Scope
  alias Mydia.MediaRequests
  alias Mydia.MetadataStubProvider

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
      poster_path: "/stub-movie-poster.jpg",
      requester_id: user.id
    }

    {:ok, request} = MediaRequests.create_request(Scope.unrestricted(), Map.merge(base, attrs))
    request
  end

  defp open_details(view, request) do
    view
    |> element(~s(#request-#{request.id} button.link[phx-click="show_details"]))
    |> render_click()

    # show_details now fetches request metadata through start_async, so
    # render_async/1 is needed to await it before callers assert on
    # detail_metadata-derived content.
    render_async(view)

    view
  end

  test "the admin page opens and closes the popup", %{conn: conn, admin: admin, guest: guest} do
    request = request_fixture(guest)

    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/admin/requests")

    refute has_element?(view, "#request-detail-modal[open]")

    open_details(view, request)

    assert has_element?(view, "#request-detail-modal[open]")
    assert render(view) =~ MetadataStubProvider.movie_title()

    # Text filter disambiguates: TrendingDetailModal always renders three
    # phx-click="close_details" buttons when open (the header's icon-only X,
    # the backdrop, and this Close button from the request pages' :actions
    # slot, which also renders in the header's action cluster), matching the
    # codebase's idiom for a modal with multiple same-selector buttons (see
    # import_media_review_test.exs). The backdrop button's text is lowercase
    # "close", so "Close" targets only the actions-slot button and not the
    # backdrop as well.
    view
    |> element(~s(#request-detail-modal button[phx-click="close_details"]), "Close")
    |> render_click()

    refute has_element?(view, "#request-detail-modal[open]")
  end

  test "My Requests opens the popup", %{conn: conn, guest: guest} do
    request = request_fixture(guest)

    {:ok, view, _html} = live(log_in_user(conn, guest), ~p"/requests")

    open_details(view, request)

    assert has_element?(view, "#request-detail-modal[open]")
  end

  test "the popup offers approve and reject on a pending request", %{
    conn: conn,
    admin: admin,
    guest: guest
  } do
    request = request_fixture(guest)

    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/admin/requests")
    open_details(view, request)

    assert has_element?(
             view,
             ~s(#request-detail-modal button[phx-click="open_approve_modal"][phx-value-id="#{request.id}"])
           )

    assert has_element?(
             view,
             ~s(#request-detail-modal button[phx-click="open_reject_modal"][phx-value-id="#{request.id}"])
           )
  end

  test "approving from the popup closes it before the approve dialog opens", %{
    conn: conn,
    admin: admin,
    guest: guest
  } do
    request = request_fixture(guest)

    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/admin/requests")
    open_details(view, request)

    view
    |> element(~s(#request-detail-modal button[phx-click="open_approve_modal"]))
    |> render_click()

    refute has_element?(view, "#request-detail-modal[open]")
    assert has_element?(view, "#approve-form")
  end

  test "switching the status filter closes an open popup", %{
    conn: conn,
    admin: admin,
    guest: guest
  } do
    request = request_fixture(guest)

    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/admin/requests")
    open_details(view, request)

    assert has_element?(view, "#request-detail-modal[open]")

    view
    |> element(~s(button[phx-click="filter"][phx-value-status="all"]))
    |> render_click()

    refute has_element?(view, "#request-detail-modal[open]")
  end

  test "a request with no resolvable id has no title button", %{
    conn: conn,
    admin: admin,
    guest: guest
  } do
    request = request_fixture(guest, %{tmdb_id: nil, imdb_id: "tt0137523"})

    {:ok, view, _html} = live(log_in_user(conn, admin), ~p"/admin/requests")

    refute has_element?(view, ~s(#request-#{request.id} button[phx-click="show_details"]))
  end
end
