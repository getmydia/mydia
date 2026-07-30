defmodule MydiaWeb.DownloadsLive.RemovedClientBannerTest do
  @moduledoc """
  The Issues tab groups orphaned downloads by the client they reference and
  offers one bulk clear per group.
  """
  # Not async: a connected LiveView mount runs in a separate process from the
  # test. Under PostgreSQL with async: true the sandbox is non-shared, so that
  # process can't see the rows this test inserts. See index_test.exs.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures
  import Mydia.AccountsFixtures

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  defp orphan(media_item, client) do
    download_fixture(%{
      media_item_id: media_item.id,
      download_client: client,
      error_message: "Download client '#{client}' is no longer configured in Mydia.",
      import_failure_reason: "no_client"
    })
  end

  test "gives colliding client names distinct DOM ids", %{conn: conn} do
    # Client names come from operator-supplied config, so two distinct names
    # can slugify to the same string. Duplicate ids are invalid HTML and make
    # LiveView's id-keyed patching update the wrong banner.
    #
    # Which name keeps the bare slug depends on collation ("Qbit Old" vs
    # "qbit-old" sort differently under SQLite's BINARY collation than under a
    # locale-aware PostgreSQL one), so this asserts only that the two ids are
    # distinct, which is the property that matters.
    media_item = media_item_fixture()
    orphan(media_item, "Qbit Old")
    orphan(media_item, "qbit-old")

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    assert has_element?(view, "#removed-client-qbit-old")
    assert has_element?(view, "#removed-client-qbit-old-2")

    # Clearing via the suffixed id removes exactly one client: the raw name
    # rides on phx-value-client, so disambiguating the id cannot misroute the
    # delete to its colliding sibling.
    view |> element("#clear-removed-client-qbit-old-2") |> render_click()

    assert has_element?(view, "#removed-client-qbit-old")
    refute has_element?(view, "#removed-client-qbit-old-2")
    assert [%{count: 1}] = Mydia.Downloads.removed_client_groups()
  end

  test "renders one banner per removed client, counting its own orphans", %{conn: conn} do
    media_item = media_item_fixture()
    orphan(media_item, "qbit-old")
    orphan(media_item, "qbit-old")
    orphan(media_item, "sab-old")

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    assert has_element?(view, "#removed-client-qbit-old")
    assert has_element?(view, "#removed-client-sab-old")

    # Each banner reports its own group's size, not the total.
    assert has_element?(view, "#removed-client-qbit-old", "2 download(s)")
    assert has_element?(view, "#removed-client-sab-old", "1 download(s)")
  end

  test "does not call a merely disabled client removed", %{conn: conn} do
    # A disabled client is still sitting in the settings list, switched off.
    # The per-row error message says so; the banner must not contradict it by
    # telling the operator the client was removed, which would steer them
    # toward deleting records whose fix is to flip the client back on.
    media_item = media_item_fixture()

    download_fixture(%{
      media_item_id: media_item.id,
      download_client: "paused",
      error_message:
        "Download client 'paused' is disabled in Mydia, so its downloads are no longer tracked.",
      import_failure_reason: "no_client"
    })

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    assert has_element?(view, "#removed-client-paused")
    refute has_element?(view, "#removed-client-paused", "removed client")
  end

  test "clears only the selected client's orphans", %{conn: conn} do
    media_item = media_item_fixture()
    doomed = orphan(media_item, "qbit-old")
    survivor = orphan(media_item, "sab-old")

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    view
    |> element("#clear-removed-client-qbit-old")
    |> render_click()

    assert_raise Ecto.NoResultsError, fn -> Mydia.Downloads.get_download!(doomed.id) end
    assert Mydia.Downloads.get_download!(survivor.id)

    refute has_element?(view, "#removed-client-qbit-old")
    assert has_element?(view, "#removed-client-sab-old")
  end

  test "shows no banner when there are no orphans", %{conn: conn} do
    media_item = media_item_fixture()
    download_fixture(%{media_item_id: media_item.id, download_client: "qbit"})

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    refute has_element?(view, "[id^='removed-client-']")
  end
end
