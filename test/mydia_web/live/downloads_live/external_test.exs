defmodule MydiaWeb.DownloadsLive.ExternalTest do
  # Not async: a connected LiveView mount runs in a separate process, and under
  # PostgreSQL the non-shared sandbox hides this test's rows from it.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads.ExternalTorrents
  alias Mydia.Downloads.Structs.{ExternalScan, ExternalTorrent}

  # Seeds the ETS cache directly. No download client is involved, which is the
  # point of keeping the scan a plain struct: the LiveView is testable without
  # one, and this repo has no client mock.
  #
  #   :media_item_id - attach a suggestion pointing at this item (default: none)
  #   :overrides     - extra %ExternalScan{} fields, e.g. failed_clients
  defp seed_scan(opts \\ []) do
    media_item_id = Keyword.get(opts, :media_item_id)
    overrides = Keyword.get(opts, :overrides, %{})

    suggestions =
      case media_item_id do
        nil ->
          []

        id ->
          [
            %{
              media_item_id: id,
              title: "The Bear",
              confidence: 0.94,
              match_reason: "Title similarity: 94.0%"
            }
          ]
      end

    external = %ExternalTorrent{
      id: "ext1",
      client_name: "qbit",
      client_id: "hash-ext",
      title: "ubuntu-24.04-desktop-amd64.iso",
      kind: :external,
      status: :seeding,
      progress: 100.0,
      size: 5_000_000
    }

    needs = %ExternalTorrent{
      id: "needs1",
      client_name: "qbit",
      client_id: "hash-needs",
      title: "The.Bear.S03E02.1080p.WEB-DL.x264-GROUP",
      kind: :needs_matching,
      status: :downloading,
      progress: 40.0,
      save_path: "/downloads/bear",
      suggestions: suggestions
    }

    scan =
      struct!(
        %ExternalScan{
          needs_matching: [needs],
          external: [external],
          scanned_at: DateTime.utc_now()
        },
        overrides
      )

    :ok = ExternalTorrents.put(scan)
    scan
  end

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin), admin: admin}
  end

  test "the external tab lists foreign torrents", %{conn: conn} do
    seed_scan()
    {:ok, view, _html} = live(conn, ~p"/downloads")

    view |> element("#downloads-tab-external") |> render_click()

    assert has_element?(view, "#external-torrents")
    assert has_element?(view, "#external_torrents-ext1")
  end

  test "foreign torrents stay out of the queue tab", %{conn: conn} do
    seed_scan()
    {:ok, view, _html} = live(conn, ~p"/downloads")

    refute has_element?(view, "#external_torrents-ext1")
    refute has_element?(view, "#downloads-ext1")
  end

  test "media-shaped torrents render in the issues needs-matching section", %{conn: conn} do
    seed_scan()
    {:ok, view, _html} = live(conn, ~p"/downloads")

    view |> element("#downloads-tab-issues") |> render_click()

    assert has_element?(view, "#needs-matching")
    assert has_element?(view, "#needs_matching-needs1")
  end

  test "an unreachable client is named rather than silently omitted", %{conn: conn} do
    seed_scan(overrides: %{failed_clients: ["broken-qbit"]})
    {:ok, view, _html} = live(conn, ~p"/downloads")

    view |> element("#downloads-tab-external") |> render_click()

    assert has_element?(view, "#external-failed-clients")
  end

  test "adopting a needs-matching torrent creates a tracked download", %{conn: conn} do
    show = media_item_fixture(%{type: "tv_show", title: "The Bear"})
    seed_scan(media_item_id: show.id)
    {:ok, view, _html} = live(conn, ~p"/downloads")

    view |> element("#downloads-tab-issues") |> render_click()

    view
    |> element("#adopt-needs1-#{show.id}")
    |> render_click()

    assert Mydia.Repo.get_by(Mydia.Downloads.Download, download_client_id: "hash-needs")
  end
end
