defmodule MydiaWeb.MediaLive.Show.GrabFlowTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Downloads.Download
  alias Mydia.Repo

  @grab_params %{
    "download-url" => "magnet:?xt=urn:btih:" <> String.duplicate("d", 40),
    "title" => "Some.Movie.2020.1080p",
    "indexer" => "test-indexer",
    "size" => "1000",
    "seeders" => "5",
    "leechers" => "1",
    "quality" => "1080p"
  }

  setup %{conn: conn} do
    admin = admin_user_fixture()
    conn = log_in_user(conn, admin)
    movie = media_item_fixture(%{type: "movie", title: "Some Movie", year: 2020})
    Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")
    %{conn: conn, movie: movie, admin: admin}
  end

  test "download click inserts the record and returns without waiting", %{
    conn: conn,
    movie: movie
  } do
    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

    # Open the modal to set manual_search_context (no indexers configured, so
    # the search async returns quickly with no results).
    render_click(view, "manual_search", %{})

    render_click(view, "download_from_search", @grab_params)

    # The record exists immediately after the click returns.
    download = Repo.get_by(Download, title: "Some.Movie.2020.1080p")
    assert download
    assert download.media_item_id == movie.id

    # The background task fails (no download clients configured) and says so.
    assert_receive {:grab_failed, %{download_id: download_id}}, 2_000
    assert download_id == download.id

    # The modal stays open by default.
    render_async(view)
    assert has_element?(view, "#manual-search-modal")
  end
end
