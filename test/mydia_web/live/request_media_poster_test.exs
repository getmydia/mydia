defmodule MydiaWeb.RequestMediaPosterTest do
  @moduledoc """
  The guest search flow must carry the search result's poster onto the request
  row, so the request list has an image without a second provider call.

  Submission used to go through the now-deleted `RequestMediaLive.Index`; it
  now goes through Discover's one-click Request button.
  """

  # async: false: setup_metadata_stub swaps the global Provider.Registry, and
  # connected LiveView mounts run outside the test process.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MetadataStub
  import Mydia.MetadataCacheHelpers

  alias Mydia.Media.MediaRequest
  alias Mydia.MetadataStubProvider
  alias Mydia.Repo

  setup :setup_metadata_stub

  setup do
    %{guest: create_test_user(%{role: "guest"})}
  end

  # request_media's create happens in a handle_info the render_click round
  # trip does not wait on. Matches the wait_until_media_item/1 helper in
  # discover_live/config_modal_test.exs.
  defp wait_until_request(clause, retries \\ 200)

  defp wait_until_request(clause, 0) do
    flunk("no MediaRequest matching #{inspect(clause)} was created in time")
  end

  defp wait_until_request(clause, retries) do
    case Repo.get_by(MediaRequest, clause) do
      nil ->
        Process.sleep(10)
        wait_until_request(clause, retries - 1)

      request ->
        request
    end
  end

  test "a submitted movie request carries the search result's poster", %{
    conn: conn,
    guest: guest
  } do
    warm_genre_cache(:movie, [])
    {:ok, view, _html} = live(log_in_user(conn, guest), ~p"/discover?type=movie&q=stub")

    view
    |> element(
      ~s(button[phx-click="request_media"][phx-value-ref="tmdb:#{MetadataStubProvider.movie_tmdb_id()}"])
    )
    |> render_click()

    request = wait_until_request(tmdb_id: MetadataStubProvider.movie_tmdb_id())

    assert request.poster_path == "/stub-movie-poster.jpg"
  end

  # `MediaRequestHelpers.handle_request_media/3` used to store the provider id
  # as tmdb_id unconditionally, even for this provider: :tvdb search result,
  # so no row was ever created under tvdb_id (see the identical note in
  # guest_request_flow_test.exs). Now fixed to branch on the result's
  # provider.
  test "a submitted series request carries the search result's poster", %{
    conn: conn,
    guest: guest
  } do
    warm_genre_cache(:tv_show, [])
    {:ok, view, _html} = live(log_in_user(conn, guest), ~p"/discover?type=tv_show&q=stub")

    view
    |> element(
      ~s(button[phx-click="request_media"][phx-value-ref="tvdb:#{MetadataStubProvider.series_tvdb_id()}"])
    )
    |> render_click()

    request = wait_until_request(tvdb_id: MetadataStubProvider.series_tvdb_id())

    assert request.poster_path == "/stub-series-poster.jpg"
  end
end
