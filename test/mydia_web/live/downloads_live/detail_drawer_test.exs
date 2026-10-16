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
end
