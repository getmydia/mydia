defmodule MydiaWeb.DownloadsLive.SeedingGoalTest do
  # Not async: swaps an adapter in the global client registry.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Structs.DownloadStatus

  defmodule ListAdapter do
    @behaviour Mydia.Downloads.Client

    def put(statuses), do: :persistent_term.put({__MODULE__, :statuses}, statuses)

    @impl true
    def list_torrents(_config, _opts),
      do: {:ok, :persistent_term.get({__MODULE__, :statuses}, [])}

    @impl true
    def supported_protocols, do: [:torrent]
    @impl true
    def test_connection(_config), do: {:error, :not_implemented}
    @impl true
    def add_torrent(_config, _torrent, _opts), do: {:error, :not_implemented}
    @impl true
    def get_status(_config, _client_id), do: {:error, :not_implemented}
    @impl true
    def pause_torrent(_config, _client_id), do: :ok
    @impl true
    def resume_torrent(_config, _client_id), do: :ok
    @impl true
    def remove_torrent(_config, _client_id, _opts), do: :ok
  end

  @guarded_hash "1111111111111111111111111111111111111111"
  @met_hash "2222222222222222222222222222222222222222"
  @plain_hash "3333333333333333333333333333333333333333"
  @unmet_hash "4444444444444444444444444444444444444444"
  @stopped_hash "5555555555555555555555555555555555555555"

  @terms %{"private" => true, "minimum_ratio" => 1.0, "minimum_seed_time" => 3 * 86_400}

  setup %{conn: conn} do
    original = Registry.lookup(:qbittorrent)
    Registry.register(:qbittorrent, ListAdapter)

    on_exit(fn ->
      :persistent_term.erase({ListAdapter, :statuses})
      if original, do: Registry.register(:qbittorrent, original)
    end)

    client = download_client_config_fixture(%{type: "qbittorrent"})
    %{conn: log_in_user(conn, admin_user_fixture()), client: client}
  end

  defp download!(client, hash, opts) do
    media_item = media_item_fixture(%{title: "Fictional Amber Causeway #{hash}"})

    download_fixture(%{
      media_item_id: media_item.id,
      indexer: "Velvet Lantern",
      download_client: client.name,
      download_client_id: hash,
      metadata: Keyword.get(opts, :metadata, %{}),
      imported_at: Keyword.get(opts, :imported_at)
    })
  end

  defp status(hash, state, ratio, seeding_time) do
    %DownloadStatus{
      id: hash,
      name: "Fictional Amber Causeway",
      state: state,
      progress: 100.0,
      ratio: ratio,
      seeding_time: seeding_time
    }
  end

  test "rows show the seeding goal and the removal confirm warns of a hit-and-run", %{
    conn: conn,
    client: client
  } do
    imported_at = DateTime.utc_now() |> DateTime.truncate(:second)

    guarded = download!(client, @guarded_hash, metadata: %{"tracker_terms" => @terms})

    met =
      download!(client, @met_hash,
        metadata: %{"tracker_terms" => @terms},
        imported_at: imported_at
      )

    plain = download!(client, @plain_hash, imported_at: imported_at)

    # A client that reports no seed time (rTorrent, rqbit), stopped: the chip
    # shows the seed time Mydia counted while it was seeding.
    stopped =
      download!(client, @stopped_hash,
        metadata: %{
          "tracker_terms" => @terms,
          "observed_seeding" => %{"seconds" => 2 * 86_400, "last_seen_at" => nil}
        },
        imported_at: imported_at
      )

    unmet =
      download!(client, @unmet_hash,
        metadata: %{"tracker_terms" => @terms},
        imported_at: imported_at
      )

    ListAdapter.put([
      status(@guarded_hash, :seeding, 0.42, 86_400),
      status(@met_hash, :seeding, 1.3, 3600),
      status(@plain_hash, :seeding, 0.1, 60),
      status(@unmet_hash, :seeding, 0.42, 86_400),
      status(@stopped_hash, :paused, 0.1, nil)
    ])

    {:ok, view, _html} = live(conn, ~p"/downloads?view=all")

    assert has_element?(view, "#download-seeding-#{guarded.id}", "0.42 / 1.0 · 1d / 3d")
    assert has_element?(view, "#download-seeding-#{met.id}", "Seeding goal met")
    refute has_element?(view, "#download-seeding-#{plain.id}")
    assert has_element?(view, "#download-seeding-#{stopped.id}", "0.10 / 1.0 · 2d / 3d")

    # In flight and under the goal: the cancel dialog names the tracker, the
    # goal and the standing, and warns. Removal stays possible.
    view |> element("#row-cancel-#{guarded.id}") |> render_click()

    assert has_element?(
             view,
             "#remove-confirm-warning",
             "Velvet Lantern requires a ratio of 1.0 or 3d of seeding"
           )

    assert has_element?(view, "#remove-confirm-warning", "at a ratio of 0.42 after 1d of seeding")
    assert has_element?(view, "#remove-confirm-warning", "hit-and-run")
    view |> element("#remove-confirm-cancel") |> render_click()

    # Goal met, or no goal at all: the remove dialog has no warning.
    for download <- [met, plain] do
      view |> element("#row-clear-#{download.id}") |> render_click()
      assert has_element?(view, "#remove-confirm-modal[open]")
      refute has_element?(view, "#remove-confirm-warning")
      view |> element("#remove-confirm-cancel") |> render_click()
    end

    view |> element("#row-clear-#{unmet.id}") |> render_click()
    assert has_element?(view, "#remove-confirm-warning", "hit-and-run")
    view |> element("#remove-confirm-cancel") |> render_click()
    refute has_element?(view, "#remove-confirm-modal")

    view |> element("#row-cancel-#{guarded.id}") |> render_click()
    view |> element("#remove-confirm-form") |> render_submit(%{"delete_files" => "true"})
    assert Mydia.Downloads.get_download!(guarded.id).removal_requested_at
  end

  # Issue #1422: with only imported torrents left, the refresh tick stopped
  # polling, so the chip and upload speed froze until the goal was met.
  test "an imported torrent's seeding progress updates on the refresh tick", %{
    conn: conn,
    client: client
  } do
    seeding =
      download!(client, @unmet_hash,
        metadata: %{"tracker_terms" => @terms},
        imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

    ListAdapter.put([%{status(@unmet_hash, :seeding, 0.42, 86_400) | upload_speed: 2048}])
    {:ok, view, _html} = live(conn, ~p"/downloads?view=imported")

    assert has_element?(view, "#download-seeding-#{seeding.id}", "0.42 / 1.0")
    assert has_element?(view, "#download-upload-#{seeding.id}", "2.0 KB/s")

    ListAdapter.put([%{status(@unmet_hash, :seeding, 0.61, 2 * 86_400) | upload_speed: 4096}])
    send(view.pid, :refresh_progress)

    assert has_element?(view, "#download-seeding-#{seeding.id}", "0.61 / 1.0 · 2d / 3d")
    assert has_element?(view, "#download-upload-#{seeding.id}", "4.0 KB/s")
  end

  test "a downloading row shows its upload speed", %{conn: conn, client: client} do
    downloading = download!(client, @guarded_hash, [])

    ListAdapter.put([
      %{status(@guarded_hash, :downloading, 0.1, nil) | progress: 40.0, upload_speed: 3072}
    ])

    {:ok, view, _html} = live(conn, ~p"/downloads")

    assert has_element?(view, "#download-upload-#{downloading.id}", "3.0 KB/s")
  end
end
