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

    {:ok, view, _html} = live(conn, ~p"/downloads?view=imported&client=beta")

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

    view |> element("#downloads-tab-issues") |> render_click()

    assert_patch(view, ~p"/downloads?tab=issues&q=salt")
  end

  test "switching view keeps the query and drops the status", %{conn: conn} do
    queued("Fictional Salt Meridian")
    {:ok, view, _html} = live(conn, ~p"/downloads?q=salt&status=queued")

    view |> element("#downloads-view-imported") |> render_click()

    assert_patch(view, ~p"/downloads?view=imported&q=salt")
  end

  test "tabs carry counts", %{conn: conn} do
    queued("Fictional Salt Meridian")
    queued("Copper Lantern")
    {:ok, view, _html} = live(conn, ~p"/downloads")

    text =
      view
      |> element("#downloads-tab-downloads-count")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.text()
      |> String.trim()

    assert text == "2"
  end

  test "changing the filters clears the selection", %{conn: conn} do
    first = queued("Fictional Salt Meridian")
    queued("Copper Lantern")
    {:ok, view, _html} = live(conn, ~p"/downloads")

    render_click(view, "toggle_select", %{"id" => first.id})
    assert has_element?(view, "#downloads-batch-bar")

    view |> form("#downloads-filter-form", %{"q" => "salt"}) |> render_change()

    refute has_element?(view, "#downloads-batch-bar")
  end

  test "a client filter survives a search change when no client select is shown", %{conn: conn} do
    queued("Fictional Salt Meridian")
    {:ok, view, _html} = live(conn, ~p"/downloads?q=salt&client=alpha")

    assert has_element?(view, "#downloads-filter-form input[type=hidden][name=client]")
    view |> form("#downloads-filter-form", %{"q" => "sal"}) |> render_change()

    assert_patch(view, ~p"/downloads?q=sal&client=alpha")
  end

  test "the stats bar is hidden with an empty queue and shown with one active download", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, ~p"/downloads")
    refute has_element?(view, "#downloads-stats")

    queued("Fictional Salt Meridian")
    {:ok, view, _html} = live(conn, ~p"/downloads")
    assert has_element?(view, "#downloads-stats")
  end

  test "removing a chip patches that filter away", %{conn: conn} do
    queued("Fictional Salt Meridian")
    {:ok, view, _html} = live(conn, ~p"/downloads?q=salt&status=queued")

    view |> element("#downloads-filter-chip-q button") |> render_click()

    assert_patch(view, ~p"/downloads?status=queued")
  end

  test "the title links to its library page", %{conn: conn} do
    download = queued("Fictional Salt Meridian")
    {:ok, view, _html} = live(conn, ~p"/downloads")

    assert has_element?(
             view,
             "#download-title-link-#{download.id}[href='/media/#{download.media_item_id}']"
           )
  end

  test "a row without a library title has no link", %{conn: conn} do
    download =
      download_fixture(%{
        media_item_id: nil,
        imported_at: nil,
        download_client: nil,
        download_client_id: nil
      })

    {:ok, view, _html} = live(conn, ~p"/downloads")

    assert has_element?(view, "#downloads-#{download.id}")
    refute has_element?(view, "#download-title-link-#{download.id}")
  end

  describe "client chip" do
    import Mydia.SettingsFixtures

    test "links to the client's web UI when one resolves", %{conn: conn} do
      client =
        download_client_config_fixture(%{
          name: "Alpha Qbit",
          enabled: false,
          web_ui_url: "https://qbit.example.org/"
        })

      download = completed("Fictional Salt Meridian", client.name)
      {:ok, view, _html} = live(conn, ~p"/downloads?view=imported")

      assert has_element?(
               view,
               "a#download-client-#{download.id}[href='https://qbit.example.org/']"
             )
    end

    test "is plain text when no client config has that name", %{conn: conn} do
      download = completed("Fictional Salt Meridian", "gone-client")
      {:ok, view, _html} = live(conn, ~p"/downloads?view=imported")

      assert has_element?(view, "span#download-client-#{download.id}")
      refute has_element?(view, "a#download-client-#{download.id}")
    end
  end

  describe "tabs and views" do
    test "Issues with nothing selectable get no Select and select nothing", %{conn: conn} do
      queued("Fictional Salt Meridian")

      {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues")
      refute has_element?(view, "button[phx-click='toggle_select_all']")

      render_click(view, "toggle_select_all", %{})
      refute has_element?(view, "#downloads-batch-bar")
    end

    test "the page has three tabs and no Queue or Completed tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloads")

      assert has_element?(view, "#downloads-tab-downloads[aria-current='page']")
      assert has_element?(view, "#downloads-tab-issues")
      assert has_element?(view, "#downloads-tab-external")
      refute has_element?(view, "#downloads-tab-queue")
      refute has_element?(view, "#downloads-tab-completed")
    end

    test "Active is the default view and lists only in-flight rows", %{conn: conn} do
      salt = queued("Fictional Salt Meridian")
      lantern = completed("Copper Lantern", "alpha")
      {:ok, view, _html} = live(conn, ~p"/downloads")

      assert has_element?(view, "#downloads-view-active.btn-primary")
      assert has_element?(view, "#downloads-#{salt.id}")
      refute has_element?(view, "#downloads-#{lantern.id}")
    end

    test "Imported and All change the rows; status chips are Active-only", %{conn: conn} do
      salt = queued("Fictional Salt Meridian")
      lantern = completed("Copper Lantern", "alpha")

      {:ok, view, _html} = live(conn, ~p"/downloads?view=imported")
      refute has_element?(view, "#downloads-#{salt.id}")
      assert has_element?(view, "#downloads-#{lantern.id}")
      refute has_element?(view, "#downloads-status-filter")

      {:ok, view, _html} = live(conn, ~p"/downloads?view=all")
      assert has_element?(view, "#downloads-#{salt.id}")
      assert has_element?(view, "#downloads-#{lantern.id}")
      refute has_element?(view, "#downloads-status-filter")
    end

    test "rows in the All view keep their own actions", %{conn: conn} do
      salt = queued("Fictional Salt Meridian")
      lantern = completed("Copper Lantern", "alpha")
      {:ok, view, _html} = live(conn, ~p"/downloads?view=all")

      assert has_element?(view, "#row-cancel-#{salt.id}")
      refute has_element?(view, "#row-clear-#{salt.id}")
      assert has_element?(view, "#row-clear-#{lantern.id}")
      refute has_element?(view, "#row-cancel-#{lantern.id}")
    end

    test "legacy ?tab=queue and ?tab=completed land on the merged tab", %{conn: conn} do
      salt = queued("Fictional Salt Meridian")
      lantern = completed("Copper Lantern", "alpha")

      {:ok, view, _html} = live(conn, ~p"/downloads?tab=queue")
      assert has_element?(view, "#downloads-tab-downloads[aria-current='page']")
      assert has_element?(view, "#downloads-#{salt.id}")

      {:ok, view, _html} = live(conn, ~p"/downloads?tab=completed")
      assert has_element?(view, "#downloads-view-imported.btn-primary")
      assert has_element?(view, "#downloads-#{lantern.id}")
    end
  end

  describe "open client shortcut" do
    import Mydia.SettingsFixtures

    test "links straight to the only client's web UI", %{conn: conn} do
      download_client_config_fixture(%{
        name: "Fictional Qbit",
        web_ui_url: "https://qbit.example.org/",
        enabled: false
      })

      {:ok, view, _html} = live(conn, ~p"/downloads")

      assert has_element?(
               view,
               "a#downloads-open-client[href='https://qbit.example.org/'][target='_blank']"
             )
    end

    test "offers a menu when several clients have web UIs", %{conn: conn} do
      download_client_config_fixture(%{
        name: "Fictional Qbit",
        web_ui_url: "https://qbit.example.org/",
        enabled: false
      })

      download_client_config_fixture(%{
        name: "Fictional Deluge",
        web_ui_url: "https://deluge.example.org/",
        enabled: false
      })

      {:ok, view, _html} = live(conn, ~p"/downloads")

      assert has_element?(view, "#downloads-open-client")
      assert has_element?(view, "a[id^='downloads-open-client-']", "Fictional Qbit")

      assert has_element?(
               view,
               "a#downloads-open-client-fictional-qbit[href='https://qbit.example.org/']"
             )

      assert has_element?(
               view,
               "a#downloads-open-client-fictional-deluge[href='https://deluge.example.org/']"
             )
    end

    test "is absent without a client", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloads")
      refute has_element?(view, "#downloads-open-client")
    end
  end
end
