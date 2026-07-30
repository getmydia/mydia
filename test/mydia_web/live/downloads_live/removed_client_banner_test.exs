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

  test "renders one banner per removed client", %{conn: conn} do
    media_item = media_item_fixture()
    orphan(media_item, "qbit-old")
    orphan(media_item, "qbit-old")
    orphan(media_item, "sab-old")

    {:ok, view, _html} = live(conn, ~p"/downloads")
    render_click(view, "switch_tab", %{"tab" => "issues"})

    assert has_element?(view, "#removed-client-qbit-old")
    assert has_element?(view, "#removed-client-sab-old")
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
