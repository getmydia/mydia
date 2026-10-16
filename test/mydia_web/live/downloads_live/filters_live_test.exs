defmodule MydiaWeb.DownloadsLive.FiltersLiveTest do
  # Not async: the connected mount runs in another process (see index_test.exs).
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  # No client configured: a recent download with no client lands on Queue as
  # "grabbing"; one with imported_at lands on Completed.
  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  defp queued(title) do
    item = media_item_fixture(%{title: title})

    download_fixture(%{
      media_item_id: item.id,
      imported_at: nil,
      download_client: nil,
      download_client_id: nil
    })
  end

  defp completed(title, client) do
    item = media_item_fixture(%{title: title})

    download_fixture(%{
      media_item_id: item.id,
      download_client: client,
      imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  test "?q= narrows the queue by title", %{conn: conn} do
    salt = queued("Fictional Salt Meridian")
    lantern = queued("Copper Lantern")

    {:ok, view, _html} = live(conn, ~p"/downloads?q=salt")

    assert has_element?(view, "#downloads-#{salt.id}")
    refute has_element?(view, "#downloads-#{lantern.id}")
    assert has_element?(view, "#downloads-filter-chip-q")
  end

  test "typing in the search box patches the URL", %{conn: conn} do
    queued("Fictional Salt Meridian")
    {:ok, view, _html} = live(conn, ~p"/downloads")

    view |> form("#downloads-filter-form", %{"q" => "salt"}) |> render_change()

    assert_patch(view, ~p"/downloads?q=salt")
  end

  test "?client= narrows Completed and the client select appears with two clients", %{conn: conn} do
    alpha = completed("Fictional Salt Meridian", "alpha")
    beta = completed("Copper Lantern", "beta")

    {:ok, view, _html} = live(conn, ~p"/downloads?tab=completed&client=beta")

    assert has_element?(view, "#downloads-client-filter")
    assert has_element?(view, "#downloads-#{beta.id}")
    refute has_element?(view, "#downloads-#{alpha.id}")
  end

  test "a filter that matches nothing shows the filtered empty state", %{conn: conn} do
    queued("Fictional Salt Meridian")
    {:ok, view, _html} = live(conn, ~p"/downloads?q=zzzz")

    assert has_element?(view, "#downloads-empty-clear-filters")
    view |> element("#downloads-clear-filters") |> render_click()
    assert_patch(view, ~p"/downloads")
  end

  test "the status filter is offered on Queue only", %{conn: conn} do
    queued("Fictional Salt Meridian")
    completed("Copper Lantern", "alpha")

    {:ok, view, _html} = live(conn, ~p"/downloads")
    assert has_element?(view, "#downloads-status-filter")

    {:ok, view, _html} = live(conn, ~p"/downloads?tab=completed&status=paused")
    refute has_element?(view, "#downloads-status-filter")
    refute has_element?(view, "#downloads-filter-chip-status")
  end

  test "?status=queued keeps grabbing rows and drops others", %{conn: conn} do
    grabbing = queued("Fictional Salt Meridian")
    {:ok, view, _html} = live(conn, ~p"/downloads?status=paused")
    refute has_element?(view, "#downloads-#{grabbing.id}")

    {:ok, view, _html} = live(conn, ~p"/downloads?status=queued")
    assert has_element?(view, "#downloads-#{grabbing.id}")
  end

  test "switching tabs keeps the query and drops the status", %{conn: conn} do
    queued("Fictional Salt Meridian")
    {:ok, view, _html} = live(conn, ~p"/downloads?q=salt&status=queued")

    view |> element("#downloads-tab-completed") |> render_click()

    assert_patch(view, ~p"/downloads?tab=completed&q=salt")
  end

  test "tabs carry counts", %{conn: conn} do
    queued("Fictional Salt Meridian")
    queued("Copper Lantern")
    {:ok, view, _html} = live(conn, ~p"/downloads")

    assert view |> element("#downloads-tab-queue-count") |> render() =~ "2"
  end
end
