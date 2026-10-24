defmodule MydiaWeb.DownloadsLive.DetailDrawerTest do
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures
  import Mydia.MetadataStub, only: [setup_metadata_stub: 1]

  setup :setup_metadata_stub

  setup %{conn: conn} do
    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  defp queued(attrs \\ %{}) do
    item = media_item_fixture(%{title: "Fictional Salt Meridian"})

    download_fixture(
      Map.merge(
        %{
          media_item_id: item.id,
          imported_at: nil,
          download_client: nil,
          download_client_id: nil
        },
        attrs
      )
    )
  end

  test "?download=<id> opens the drawer", %{conn: conn} do
    download = queued()
    {:ok, view, _html} = live(conn, ~p"/downloads?download=#{download.id}")

    assert has_element?(view, "#download-detail")
    assert has_element?(view, "#download-detail-release")
    assert has_element?(view, "#download-detail-timeline")
  end

  test "an imported download opened on the Queue tab gets completed actions", %{conn: conn} do
    download = queued(%{imported_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    {:ok, view, _html} = live(conn, ~p"/downloads?download=#{download.id}")

    assert has_element?(view, "#drawer-clear-#{download.id}")
    refute has_element?(view, "#drawer-pause-#{download.id}")
  end

  test "the Details row action opens it and the close button patches it away", %{conn: conn} do
    download = queued()
    {:ok, view, _html} = live(conn, ~p"/downloads")

    view |> element("#download-details-#{download.id}") |> render_click()
    assert_patch(view, ~p"/downloads?download=#{download.id}")
    assert has_element?(view, "#download-detail")

    view |> element("#download-detail-close") |> render_click()
    assert_patch(view, ~p"/downloads")
    refute has_element?(view, "#download-detail")
  end

  test "an unknown id renders no drawer and says so", %{conn: conn} do
    queued()
    {:ok, view, _html} = live(conn, ~p"/downloads?download=#{Ecto.UUID.generate()}")

    refute has_element?(view, "#download-detail")
    assert has_element?(view, "#flash-info")
  end

  test "shows the full import error", %{conn: conn} do
    download =
      queued(%{
        import_last_error: "permission denied writing /library/Fictional Salt Meridian",
        import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    {:ok, view, _html} = live(conn, ~p"/downloads?download=#{download.id}")

    assert has_element?(view, "#download-detail-import-error")
  end

  test "warns when an import was copied instead of hardlinked", %{conn: conn} do
    download =
      queued(%{
        metadata: %{"import_placement" => %{"method" => "copy", "reason" => "link_refused"}}
      })

    {:ok, view, _html} = live(conn, ~p"/downloads?download=#{download.id}")

    assert has_element?(view, "#import-placement-warning")
  end

  test "no placement warning for a hardlinked import", %{conn: conn} do
    download = queued(%{metadata: %{"import_placement" => %{"method" => "hardlink"}}})

    {:ok, view, _html} = live(conn, ~p"/downloads?download=#{download.id}")

    assert has_element?(view, "#download-detail")
    refute has_element?(view, "#import-placement-warning")
  end

  test "never renders the download URL", %{conn: conn} do
    download =
      queued(%{download_url: "https://indexer.example.org/api?apikey=SECRETKEY123&t=get"})

    {:ok, view, _html} = live(conn, ~p"/downloads?download=#{download.id}")

    assert has_element?(view, "#download-detail")
    assert has_element?(view, "#download-detail-release")
    refute render(view) =~ "SECRETKEY123"
  end

  test "Escape closes the drawer", %{conn: conn} do
    download = queued()
    {:ok, view, _html} = live(conn, ~p"/downloads?download=#{download.id}")

    view |> element("#download-detail") |> render_keydown(%{"key" => "Escape"})

    assert_patch(view, ~p"/downloads")
    refute has_element?(view, "#download-detail")
  end

  test "the backdrop closes the drawer", %{conn: conn} do
    download = queued()
    {:ok, view, _html} = live(conn, ~p"/downloads?download=#{download.id}")

    view |> element("#download-detail-backdrop") |> render_click()

    assert_patch(view, ~p"/downloads")
    refute has_element?(view, "#download-detail")
  end

  test "the timeline lists only the events reached", %{conn: conn} do
    download = queued()
    {:ok, view, _html} = live(conn, ~p"/downloads?download=#{download.id}")

    assert has_element?(view, "#download-detail-event-grabbed")
    refute has_element?(view, "#download-detail-event-imported")
  end

  test "Change match closes the drawer so the match dialog is not hidden behind it", %{
    conn: conn
  } do
    download = queued()
    {:ok, view, _html} = live(conn, ~p"/downloads?download=#{download.id}")

    view |> element("#drawer-change-match-#{download.id}") |> render_click()

    refute has_element?(view, "#download-detail")
    assert has_element?(view, "#match-modal")
  end

  describe "path-mapping failures" do
    defp mismatch(reported_path) do
      queued(%{
        status: "completed",
        import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
        import_failure_reason: "path_mapping_mismatch",
        import_reported_path: reported_path,
        import_last_error: "Mydia can't access the download path: #{reported_path}."
      })
    end

    # A basename no mount holds, so no suggestion can be found for it.
    test "without a suggestion, explains the failure and links to Path Mappings", %{conn: conn} do
      download = mismatch("/no-such-mydia-mount/Fictional.Salt.Meridian.S01E01")

      {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues&download=#{download.id}")

      assert has_element?(
               view,
               "#drawer-path-mapping",
               "Mydia can't see the download client's path"
             )

      assert has_element?(view, "#drawer-path-mapping a[href='/admin/path-mappings']")
      refute has_element?(view, "#drawer-apply-mapping-#{download.id}")
    end

    test "with a suggestion, shows the prefixes and Apply mapping", %{conn: conn} do
      download = mismatch("/downloads/complete/Fictional.Salt.Meridian.S01E01")
      {:ok, _view, _html} = live(conn, ~p"/downloads")

      row =
        Mydia.Downloads.list_downloads_with_status(bounded: true)
        |> Enum.find(&(&1.id == download.id))

      row = %{
        row
        | path_mapping_suggestion: %{
            remote_prefix: "/downloads/complete",
            local_prefix: "/data/torrents/complete"
          },
          path_mapping_affected_count: 2
      }

      html =
        render_component(&MydiaWeb.DownloadsLive.DetailDrawer.detail_drawer/1,
          download: row,
          tab: :issues,
          display: %Mydia.TimeDisplay{}
        )

      doc = LazyHTML.from_fragment(html)
      block = LazyHTML.query(doc, "#drawer-path-mapping")

      assert LazyHTML.text(block) =~ "Mydia can't see the download client's path"
      assert LazyHTML.text(block) =~ "/downloads/complete"
      assert LazyHTML.text(block) =~ "/data/torrents/complete"
      assert LazyHTML.text(block) =~ "Retries 2 downloads"

      assert doc
             |> LazyHTML.query(
               "#drawer-apply-mapping-#{download.id}[phx-click=apply_mapping_and_retry]"
             )
             |> Enum.count() == 1
    end

    test "is absent once the failure is cleared, though the stale reason remains", %{conn: conn} do
      download =
        queued(%{
          status: "completed",
          import_failed_at: nil,
          import_failure_reason: "path_mapping_mismatch",
          import_last_error: "Mydia can't access the download path: /gone."
        })

      {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues&download=#{download.id}")

      assert has_element?(view, "#download-detail-import-error")
      refute has_element?(view, "#drawer-path-mapping")
    end

    test "is absent for other import failures", %{conn: conn} do
      download =
        queued(%{
          import_last_error: "permission denied",
          import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues&download=#{download.id}")

      assert has_element?(view, "#download-detail-import-error")
      refute has_element?(view, "#drawer-path-mapping")
    end
  end
end
