defmodule MydiaWeb.DownloadsLive.IssuesSectionsTest do
  # Not async: the connected mount runs in another process (see index_test.exs).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  test "only sections with items render, as bordered cards", %{conn: conn} do
    item = media_item_fixture(%{title: "Fictional Salt Meridian"})

    download_fixture(%{
      media_item_id: item.id,
      download_client: nil,
      download_client_id: nil,
      import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      import_last_error: "permission denied"
    })

    {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues")

    assert has_element?(view, "#issues-other.card.card-border")
    refute has_element?(view, "#issues-needs-matching")
    refute has_element?(view, "#issues-unresolved")
    refute has_element?(view, "#downloads-empty-state")
  end

  test "with no issues, the tab shows one empty state and no sections", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues")

    assert has_element?(view, "#downloads-empty-state")
    refute has_element?(view, "#issues-needs-matching")
    refute has_element?(view, "#issues-unresolved")
    refute has_element?(view, "#issues-other")
  end
end
