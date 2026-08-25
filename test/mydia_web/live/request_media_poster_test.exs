defmodule MydiaWeb.RequestMediaPosterTest do
  @moduledoc """
  The guest search flow must carry the search result's poster onto the request
  row, so the request pages have an image without a second provider call.
  """

  # async: false: setup_metadata_stub swaps the global Provider.Registry, and
  # connected LiveView mounts run outside the test process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataStub

  alias Mydia.Media.MediaRequest
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo

  setup :setup_metadata_stub

  setup do
    %{guest: create_test_user(%{role: "guest"})}
  end

  test "a submitted movie request carries the search result's poster", %{
    conn: conn,
    guest: guest
  } do
    {:ok, view, _html} = live(log_in_user(conn, guest), ~p"/request/movie?q=stub")

    view
    |> element(~s(button[phx-click="open_request_modal"][phx-value-index="0"]))
    |> render_click()

    view
    |> form("#request-modal-form", request: %{requester_notes: ""})
    |> render_submit()

    request = Repo.get_by!(MediaRequest, tmdb_id: MetadataStubProvider.movie_tmdb_id())

    assert request.poster_path == "/stub-movie-poster.jpg"
  end

  test "a submitted series request carries the search result's poster", %{
    conn: conn,
    guest: guest
  } do
    {:ok, view, _html} = live(log_in_user(conn, guest), ~p"/request/series?q=stub")

    view
    |> element(~s(button[phx-click="open_request_modal"][phx-value-index="0"]))
    |> render_click()

    view
    |> form("#request-modal-form", request: %{requester_notes: ""})
    |> render_submit()

    request = Repo.get_by!(MediaRequest, tvdb_id: MetadataStubProvider.series_tvdb_id())

    assert request.poster_path == "/stub-series-poster.jpg"
  end
end
