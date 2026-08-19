defmodule MydiaWeb.MediaLive.Show.DownloadEventsMissingRowTest do
  @moduledoc """
  Issue #281: the download-related events on the media detail page loaded their
  row with the raising `get_download!/2`.

  The id comes from the rendered page, so it can name a row that is already gone
  by the time the click lands — an import that finished and cleaned up, another
  tab, or `DownloadMonitor`'s reject path. That crashed the LiveView process
  rather than telling the operator anything.

  The row is deleted in setup, which is exactly the state a stale browser tab is
  in when the operator clicks.
  """
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures
  import MydiaWeb.AuthHelpers

  alias Mydia.Downloads

  setup %{conn: conn} do
    admin = admin_user_fixture()
    conn = log_in_user(conn, admin)
    movie = media_item_fixture(%{type: "movie", title: "Some Movie", year: 2020})

    download = download_fixture(%{media_item_id: movie.id})
    {:ok, _} = Downloads.delete_download(download)

    %{conn: conn, movie: movie, stale_id: download.id}
  end

  for event <- ~w(show_download_cancel_confirm show_download_delete_confirm
                  show_download_details retry_download) do
    test "#{event} tells the operator instead of crashing the socket", %{
      conn: conn,
      movie: movie,
      stale_id: stale_id
    } do
      {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

      assert render_click(view, unquote(event), %{"download-id" => stale_id}) =~
               "That download no longer exists."
    end
  end

  # Keyed on "id" rather than "download-id", and it is the one that carried a
  # strict `{:ok, _} = delete_download(...)` match — which, now that a vanished
  # row returns `{:error, changeset}` instead of raising `Ecto.StaleEntryError`,
  # would have become a MatchError.
  test "dismiss_failed_grab survives a row another tab already dismissed", %{
    conn: conn,
    movie: movie,
    stale_id: stale_id
  } do
    {:ok, view, _html} = live(conn, ~p"/media/#{movie.id}")

    assert render_click(view, "dismiss_failed_grab", %{"id" => stale_id}) =~
             "That download no longer exists."
  end
end
