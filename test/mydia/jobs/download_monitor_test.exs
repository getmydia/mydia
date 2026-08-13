defmodule Mydia.Jobs.DownloadMonitorTest do
  use Mydia.DataCase, async: true
  use Oban.Testing, repo: Mydia.Repo

  import Ecto.Query

  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.ReleaseBlacklist
  alias Mydia.Jobs.DownloadMonitor
  alias Mydia.Downloads
  alias Mydia.Downloads.Download
  alias Mydia.Events
  alias Mydia.Repo
  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures
  import Mydia.SettingsFixtures

  describe "perform/1" do
    test "successfully monitors downloads with no active downloads" do
      setup_runtime_config([])
      assert :ok = perform_job(DownloadMonitor, %{})
    end

    test "handles no configured download clients gracefully" do
      setup_runtime_config([])

      # Create an active download
      media_item = media_item_fixture()
      download_fixture(%{media_item_id: media_item.id})

      assert :ok = perform_job(DownloadMonitor, %{})
    end

    test "successfully monitors active downloads" do
      setup_runtime_config([build_test_client_config()])
      media_item = media_item_fixture()

      # Create downloads with different completion states
      download_fixture(%{media_item_id: media_item.id})
      download_fixture(%{media_item_id: media_item.id})
      download_fixture(%{media_item_id: media_item.id, completed_at: DateTime.utc_now()})

      assert :ok = perform_job(DownloadMonitor, %{})
    end

    test "processes active and completed downloads" do
      setup_runtime_config([build_test_client_config()])
      media_item = media_item_fixture()

      # Create active downloads (will be marked missing since they don't exist in client)
      active1 = download_fixture(%{media_item_id: media_item.id})
      active2 = download_fixture(%{media_item_id: media_item.id})

      # Create completed and failed downloads (will be kept)
      completed =
        download_fixture(%{media_item_id: media_item.id, completed_at: DateTime.utc_now()})

      failed = download_fixture(%{media_item_id: media_item.id, error_message: "Failed"})

      # Job should complete successfully
      assert :ok = perform_job(DownloadMonitor, %{})

      # Active downloads should be marked with error_message (preserved for Issues tab)
      # Note: "status" is calculated dynamically, but error_message persists
      updated_active1 = Downloads.get_download!(active1.id)
      updated_active2 = Downloads.get_download!(active2.id)
      assert updated_active1.error_message =~ "no longer configured in Mydia"
      assert updated_active2.error_message =~ "no longer configured in Mydia"

      # Completed and failed downloads should still exist
      assert Downloads.get_download!(completed.id)
      assert Downloads.get_download!(failed.id)
    end

    test "marks downloads without an assigned client as missing" do
      setup_runtime_config([build_test_client_config()])
      media_item = media_item_fixture()

      # Create download without a download_client (will be marked as missing)
      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: nil
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # Download should have error_message set (preserved for Issues tab)
      updated = Downloads.get_download!(download.id)
      assert updated.error_message =~ "Removed from download client"
    end

    test "marks downloads with non-existent client as missing" do
      setup_runtime_config([build_test_client_config()])
      media_item = media_item_fixture()

      # Create download with a client that doesn't exist in config
      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "NonExistentClient",
          download_client_id: "test123"
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # Download should have error_message set (preserved for Issues tab)
      updated = Downloads.get_download!(download.id)
      assert updated.error_message =~ "NonExistentClient"
    end

    test "processes multiple downloads in a single run" do
      setup_runtime_config([build_test_client_config()])
      media_item = media_item_fixture()

      # Create multiple downloads (will be marked missing since they don't exist in client)
      d1 =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Download 1"
        })

      d2 =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Download 2"
        })

      d3 = download_fixture(%{media_item_id: media_item.id, title: "Download 3"})

      # Should process all downloads without crashing
      assert :ok = perform_job(DownloadMonitor, %{})

      # All downloads should have error_message set (preserved for Issues tab)
      assert Downloads.get_download!(d1.id).error_message =~ "no longer configured in Mydia"
      assert Downloads.get_download!(d2.id).error_message =~ "no longer configured in Mydia"
      assert Downloads.get_download!(d3.id).error_message =~ "no longer configured in Mydia"
    end

    test "marks downloads from disabled clients as missing" do
      # Configure a disabled client
      disabled_client = %{
        build_test_client_config()
        | name: "DisabledClient",
          enabled: false
      }

      setup_runtime_config([disabled_client])
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "DisabledClient",
          download_client_id: "test123"
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # Download should have error_message set since disabled clients are not queried
      updated = Downloads.get_download!(download.id)
      assert updated.error_message =~ "DisabledClient"
    end

    test "sorts download clients by priority" do
      # Configure multiple clients with different priorities
      client1 = %{build_test_client_config() | name: "Client1", priority: 3}
      client2 = %{build_test_client_config() | name: "Client2", priority: 1}
      client3 = %{build_test_client_config() | name: "Client3", priority: 2}

      setup_runtime_config([client1, client2, client3])

      # Job should complete successfully with clients sorted by priority
      assert :ok = perform_job(DownloadMonitor, %{})
    end

    test "handles downloads for different client types" do
      setup_runtime_config([
        build_test_client_config(%{name: "qBit", type: :qbittorrent}),
        build_test_client_config(%{name: "Trans", type: :transmission})
      ])

      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "qBit",
        download_client_id: "hash1"
      })

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "Trans",
        download_client_id: "id2"
      })

      assert :ok = perform_job(DownloadMonitor, %{})
    end

    test "does NOT mark downloads missing when their client is unreachable" do
      # Client is configured by name but unreachable on the network. This is the
      # exact failure mode behind the recurring "qBittorrent downloads vanish"
      # reports: a brief client restart used to flag every active download as
      # missing within a single monitor cycle.
      setup_runtime_config([
        build_test_client_config(%{name: "qBit-down", host: "127.0.0.1", port: 1})
      ])

      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "qBit-down",
          download_client_id: "abc123def456abc123def456abc123def456abcd"
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # The download must NOT be marked missing — we can't tell from an
      # unreachable client whether the torrent is gone or not.
      updated = Downloads.get_download!(download.id)
      assert is_nil(updated.error_message)
      assert is_nil(updated.completed_at)
    end
  end

  describe "missing download detection" do
    test "marks downloads that no longer exist in any client as missing" do
      # Setup with no actual clients (simulates missing downloads). This is
      # also the single-client operator's shape: deleting your only client
      # leaves `all_configured == []`, and that must still classify as
      # :removed rather than silently falling back to nil.
      setup_runtime_config([])

      media_item = media_item_fixture()

      # Create a download that exists in DB but not in any client
      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "test-client",
          download_client_id: "missing-123"
        })

      # Verify download exists before job runs
      assert Downloads.get_download!(download.id)

      # Run the job
      assert :ok = perform_job(DownloadMonitor, %{})

      # Download should have error_message set (preserved for Issues tab)
      updated = Downloads.get_download!(download.id)
      assert updated.error_message =~ "no longer configured in Mydia"
      assert updated.error_message =~ "test-client"
      # The `no_client` tag is what Task 5's Issues tab groups and
      # bulk-clears on — it must still be written when there is no
      # configured client at all, not just when a mismatched one exists.
      assert updated.import_failure_reason == "no_client"
    end

    test "does not remove downloads that are already completed" do
      setup_runtime_config([])

      media_item = media_item_fixture()

      # Create a completed download
      download =
        download_fixture(%{
          media_item_id: media_item.id,
          completed_at: DateTime.utc_now()
        })

      # Run the job
      assert :ok = perform_job(DownloadMonitor, %{})

      # Completed download should still exist (status will be "completed")
      assert Downloads.get_download!(download.id)
    end

    test "does not remove downloads that have error messages" do
      setup_runtime_config([])

      media_item = media_item_fixture()

      # Create a failed download
      download =
        download_fixture(%{
          media_item_id: media_item.id,
          error_message: "Download failed"
        })

      # Run the job
      assert :ok = perform_job(DownloadMonitor, %{})

      # Failed download should still exist (status will be "failed")
      assert Downloads.get_download!(download.id)
    end

    test "marks multiple missing downloads in a single run" do
      setup_runtime_config([])

      media_item = media_item_fixture()

      # Create multiple downloads that don't exist in any client
      download1 =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "test-client",
          download_client_id: "missing-1"
        })

      download2 =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "test-client",
          download_client_id: "missing-2"
        })

      download3 =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "test-client",
          download_client_id: "missing-3"
        })

      # Run the job
      assert :ok = perform_job(DownloadMonitor, %{})

      # All missing downloads should have error_message set (preserved for Issues tab)
      assert Downloads.get_download!(download1.id).error_message =~
               "no longer configured in Mydia"

      assert Downloads.get_download!(download2.id).error_message =~
               "no longer configured in Mydia"

      assert Downloads.get_download!(download3.id).error_message =~
               "no longer configured in Mydia"
    end

    test "handles mix of missing, active, and completed downloads" do
      setup_runtime_config([])

      media_item = media_item_fixture()

      # Create a missing download (will be marked missing)
      missing_download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Missing Download"
        })

      # Create a completed download (will be kept)
      completed_download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Completed Download",
          completed_at: DateTime.utc_now()
        })

      # Create a failed download (will be kept)
      failed_download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Failed Download",
          error_message: "Download failed in client"
        })

      # Run the job
      assert :ok = perform_job(DownloadMonitor, %{})

      # The missing download should have error_message set (preserved for Issues tab)
      updated_missing = Downloads.get_download!(missing_download.id)
      assert updated_missing.error_message =~ "no longer configured in Mydia"

      # Completed and failed downloads should still exist unchanged
      assert Downloads.get_download!(completed_download.id)
      assert Downloads.get_download!(failed_download.id)
    end

    test "broadcasts download update when marking missing download" do
      setup_runtime_config([])

      media_item = media_item_fixture()

      _download =
        download_fixture(%{
          media_item_id: media_item.id
        })

      # Subscribe to download updates
      Phoenix.PubSub.subscribe(Mydia.PubSub, "downloads")

      # Run the job
      assert :ok = perform_job(DownloadMonitor, %{})

      # Should receive update notification
      assert_received {:download_updated, _download_id}
    end
  end

  describe "missing download preservation" do
    test "preserves a matched download that goes missing (regression guard)" do
      # Matched downloads still go through the `missing` handler — the user
      # may want to investigate why their tracked torrent disappeared.
      setup_runtime_config([])
      media_item = media_item_fixture()

      # match_status is nil for normally-matched downloads (the enum is
      # ["unresolved_files", "partial_pack"]).
      tracked =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "test-client",
          download_client_id: "tracked-1"
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      preserved = Mydia.Repo.get(Mydia.Downloads.Download, tracked.id)
      assert preserved
      assert preserved.error_message =~ "no longer configured in Mydia"
    end

    test "the downloads schema rejects the retired unmatched status" do
      # Foreign torrents are derived by Mydia.Downloads.ExternalTorrents and
      # never written, so nothing may reintroduce the value the self-healing
      # above used to clean up.
      changeset =
        Mydia.Downloads.Download.changeset(%Mydia.Downloads.Download{}, %{
          title: "x",
          indexer: "manual",
          download_client: "qbit",
          download_client_id: "hash-a",
          match_status: "unmatched"
        })

      refute changeset.valid?
      assert %{match_status: _} = errors_on(changeset)
    end
  end

  describe "stale grab self-healing" do
    test "persists 'Grab timed out' on a backdated client-less record" do
      setup_runtime_config([])

      download =
        download_fixture(%{download_client: nil, download_client_id: nil})
        |> backdate(Downloads.grab_timeout_minutes() + 1)

      assert :ok = perform_job(DownloadMonitor, %{})

      updated = Downloads.get_download!(download.id)
      assert updated.error_message == "Grab timed out"
    end

    test "leaves a fresh client-less record untouched" do
      setup_runtime_config([])

      download = download_fixture(%{download_client: nil, download_client_id: nil})

      assert :ok = perform_job(DownloadMonitor, %{})

      updated = Downloads.get_download!(download.id)
      assert is_nil(updated.error_message)
    end
  end

  describe "stuck download detection" do
    test "detects and flags downloads that completed but never imported" do
      setup_runtime_config([])
      media_item = media_item_fixture()

      # Create a stuck download - completed more than 1 hour ago but never imported
      two_hours_ago = DateTime.add(DateTime.utc_now(), -2, :hour)

      stuck_download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Stuck Download",
          download_client: "test-client",
          download_client_id: "stuck-123",
          completed_at: two_hours_ago,
          imported_at: nil,
          import_failed_at: nil
        })

      # Verify download exists and has no failure before job runs
      assert Downloads.get_download!(stuck_download.id)
      assert is_nil(stuck_download.import_failed_at)

      # Run the job
      assert :ok = perform_job(DownloadMonitor, %{})

      # Stuck download should now have import_failed_at set
      updated = Downloads.get_download!(stuck_download.id)
      assert updated.import_failed_at != nil
      assert updated.import_last_error =~ "Import stalled"
    end

    test "enqueues import retry job for stuck downloads" do
      setup_runtime_config([])
      media_item = media_item_fixture()

      # Create a stuck download
      two_hours_ago = DateTime.add(DateTime.utc_now(), -2, :hour)

      stuck_download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Stuck Download",
          download_client: "test-client",
          download_client_id: "stuck-456",
          completed_at: two_hours_ago,
          imported_at: nil,
          import_failed_at: nil
        })

      # Run the job
      assert :ok = perform_job(DownloadMonitor, %{})

      # Should have enqueued a MediaImport job for the stuck download
      assert_enqueued(
        worker: Mydia.Jobs.MediaImport,
        args: %{"download_id" => stuck_download.id}
      )
    end

    test "does not flag recently completed downloads as stuck" do
      setup_runtime_config([])
      media_item = media_item_fixture()

      # Create a recently completed download (30 minutes ago - not stuck yet)
      thirty_minutes_ago = DateTime.add(DateTime.utc_now(), -30, :minute)

      recent_download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Recent Download",
          download_client: "test-client",
          download_client_id: "recent-123",
          completed_at: thirty_minutes_ago,
          imported_at: nil,
          import_failed_at: nil
        })

      # Run the job
      assert :ok = perform_job(DownloadMonitor, %{})

      # Recent download should NOT have import_failed_at set
      # (but it will be marked as missing since it's not in any client)
      updated = Downloads.get_download!(recent_download.id)
      # import_failed_at should still be nil (not flagged as stuck)
      assert is_nil(updated.import_failed_at)
    end

    test "does not flag already imported downloads" do
      setup_runtime_config([])
      media_item = media_item_fixture()

      # Create an already imported download
      two_hours_ago = DateTime.add(DateTime.utc_now(), -2, :hour)

      imported_download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Imported Download",
          download_client: "test-client",
          download_client_id: "imported-123",
          completed_at: two_hours_ago,
          imported_at: DateTime.utc_now(),
          import_failed_at: nil
        })

      # Run the job
      assert :ok = perform_job(DownloadMonitor, %{})

      # Should not be modified (already imported)
      updated = Downloads.get_download!(imported_download.id)
      assert is_nil(updated.import_failed_at)
      assert updated.imported_at != nil
    end

    test "does not flag downloads that already have import_failed_at" do
      setup_runtime_config([])
      media_item = media_item_fixture()

      # Create a download that already has a failure tracked
      two_hours_ago = DateTime.add(DateTime.utc_now(), -2, :hour)

      already_failed =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Already Failed Download",
          download_client: "test-client",
          download_client_id: "failed-123",
          completed_at: two_hours_ago,
          imported_at: nil,
          import_failed_at: two_hours_ago,
          import_last_error: "Previous failure"
        })

      # Run the job
      assert :ok = perform_job(DownloadMonitor, %{})

      # Should not be modified (already has failure)
      updated = Downloads.get_download!(already_failed.id)
      assert updated.import_last_error == "Previous failure"
    end
  end

  describe "stall detection" do
    test "initializes last_progress_at the first time an active download is observed" do
      # No clients configured — the active download will be in "missing" state,
      # so it won't reach the stall-tracking path. Initialization happens only
      # for downloads whose client reports them. Validate that path via Bypass.
      {bypass, client_config} = start_sabnzbd_bypass()

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-init-1", "test.nzb", size_mb: 100.0, mb_left: 50.0)
      ])

      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-init-1",
          last_progress_at: nil,
          last_known_bytes: 0
        })

      now = ~U[2026-05-14 12:00:00.000000Z]

      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      updated = Downloads.get_download!(download.id)

      # First observation: last_progress_at initialized to `now`, bytes captured.
      assert updated.last_progress_at == now
      assert updated.last_known_bytes == round(50.0 * 1024 * 1024)
      assert is_nil(updated.import_failed_at)
    end

    test "updates last_progress_at and last_known_bytes when bytes increase" do
      {bypass, client_config} = start_sabnzbd_bypass()

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-progress-1", "test.nzb", size_mb: 100.0, mb_left: 40.0)
      ])

      media_item = media_item_fixture()

      first_seen = ~U[2026-05-14 11:00:00.000000Z]
      prev_bytes = round(50.0 * 1024 * 1024)

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-progress-1",
          last_progress_at: first_seen,
          last_known_bytes: prev_bytes,
          # Observed one poll ago — within the observation-gap window, so the
          # gap reset doesn't pre-empt progress evaluation.
          last_observed_at: ~U[2026-05-14 11:58:00.000000Z]
        })

      now = ~U[2026-05-14 12:00:00.000000Z]
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      updated = Downloads.get_download!(download.id)
      # Bytes increased from ~50MB to ~60MB — progress recorded, no stall flag.
      assert updated.last_progress_at == now
      assert updated.last_known_bytes == round(60.0 * 1024 * 1024)
      assert updated.last_observed_at == now
      assert is_nil(updated.import_failed_at)
      assert is_nil(updated.stalled_since)
    end

    test "leaves last_progress_at unchanged when bytes are unchanged within grace window" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 60)

      same_bytes = round(50.0 * 1024 * 1024)

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-stuck-1", "test.nzb", size_mb: 100.0, mb_left: 50.0)
      ])

      media_item = media_item_fixture()

      first_seen = ~U[2026-05-14 11:30:00.000000Z]

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-stuck-1",
          last_progress_at: first_seen,
          last_known_bytes: same_bytes,
          # Half-stale (5 min > the 180s refresh threshold) so the no-change
          # path refreshes last_observed_at this poll.
          last_observed_at: ~U[2026-05-14 11:55:00.000000Z]
        })

      # 30 minutes after first_seen — still within the 60-minute grace window.
      now = ~U[2026-05-14 12:00:00.000000Z]
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      updated = Downloads.get_download!(download.id)
      assert updated.last_progress_at == first_seen
      assert updated.last_known_bytes == same_bytes
      # last_observed_at refreshed because it was half-stale.
      assert updated.last_observed_at == now
      assert is_nil(updated.import_failed_at)
      assert is_nil(updated.stalled_since)
    end

    test "does not rewrite last_observed_at on a no-change poll when it is still fresh" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 60)

      same_bytes = round(50.0 * 1024 * 1024)

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-fresh-1", "test.nzb", size_mb: 100.0, mb_left: 50.0)
      ])

      media_item = media_item_fixture()

      # Observed 1 minute ago — well inside the 180s refresh threshold, so the
      # idle poll must not issue a redundant write/broadcast.
      fresh_observed = ~U[2026-05-14 11:59:00.000000Z]

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-fresh-1",
          last_progress_at: ~U[2026-05-14 11:30:00.000000Z],
          last_known_bytes: same_bytes,
          last_observed_at: fresh_observed
        })

      now = ~U[2026-05-14 12:00:00.000000Z]
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      updated = Downloads.get_download!(download.id)
      assert updated.last_observed_at == fresh_observed
      assert is_nil(updated.import_failed_at)
      assert is_nil(updated.stalled_since)
    end

    test "does not stall at the exact grace boundary (strict >)" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 60)

      same_bytes = round(50.0 * 1024 * 1024)

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-boundary-1", "test.nzb", size_mb: 100.0, mb_left: 50.0)
      ])

      media_item = media_item_fixture()

      first_seen = ~U[2026-05-14 11:00:00.000000Z]
      # exactly 60 minutes later (== grace) — strict > means NOT yet stalled.
      now = ~U[2026-05-14 12:00:00.000000Z]

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-boundary-1",
          last_progress_at: first_seen,
          last_known_bytes: same_bytes,
          last_observed_at: ~U[2026-05-14 11:58:00.000000Z]
        })

      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      updated = Downloads.get_download!(download.id)
      assert is_nil(updated.import_failed_at)
      assert is_nil(updated.import_last_error)
      assert is_nil(updated.stalled_since)
    end

    test "soft-stalls (not terminal) when bytes are unchanged past the grace window" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 60)

      same_bytes = round(50.0 * 1024 * 1024)

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-stalled-1", "test.nzb", size_mb: 100.0, mb_left: 50.0)
      ])

      media_item = media_item_fixture()

      first_seen = ~U[2026-05-14 10:00:00.000000Z]
      # 61 minutes later — past the 60m grace window by 1 minute. Observed
      # continuously (recent last_observed_at) so no gap reset.
      now = ~U[2026-05-14 11:01:00.000000Z]

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-stalled-1",
          last_progress_at: first_seen,
          last_known_bytes: same_bytes,
          last_observed_at: ~U[2026-05-14 10:59:00.000000Z]
        })

      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      updated = Downloads.get_download!(download.id)
      # Soft-stall: stalled_since set, but NOT terminal — import_failed_at stays
      # nil so the episode is still occupied (no re-grab).
      assert updated.stalled_since != nil
      assert DateTime.diff(updated.stalled_since, now, :second) == 0
      assert updated.last_observed_at == now
      assert is_nil(updated.import_failed_at)
      assert is_nil(updated.import_last_error)

      # A soft-stall emits a warning event, not a terminal failure.
      Process.sleep(100)
      assert Events.list_events(type: "download.stalled") != []
      assert Events.list_events(type: "download.failed") == []
    end

    test "respects per-client incomplete_grace_minutes for soft-stall" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 15)

      same_bytes = round(50.0 * 1024 * 1024)

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-grace15-1", "test.nzb", size_mb: 100.0, mb_left: 50.0)
      ])

      media_item = media_item_fixture()

      first_seen = ~U[2026-05-14 10:00:00.000000Z]
      # 16 minutes later — past the 15m grace window.
      now = ~U[2026-05-14 10:16:00.000000Z]

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-grace15-1",
          last_progress_at: first_seen,
          last_known_bytes: same_bytes,
          last_observed_at: ~U[2026-05-14 10:14:00.000000Z]
        })

      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      updated = Downloads.get_download!(download.id)
      assert updated.stalled_since != nil
      assert DateTime.diff(updated.stalled_since, now, :second) == 0
      assert is_nil(updated.import_failed_at)
    end

    test "does not flag stalled in terminal state (completed)" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 5)

      mock_sabnzbd_queue(bypass, [],
        history: [
          sabnzbd_history_item("nzo-completed-1", "test.nzb", "Completed")
        ]
      )

      media_item = media_item_fixture()

      # Last progress was 1 hour ago — well past the 5-minute grace — but
      # the client now reports the download as completed, so stall detection
      # must not kick in. We also set `completed_at` and `imported_at` so the
      # other monitor branches (handle_completion, list_stuck_downloads) treat
      # this row as already done — leaving only the stall-tracking path under
      # test.
      first_seen = ~U[2026-05-14 10:00:00.000000Z]
      now = ~U[2026-05-14 11:00:00.000000Z]
      bytes = round(50.0 * 1024 * 1024)

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-completed-1",
          last_progress_at: first_seen,
          last_known_bytes: bytes,
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      updated = Downloads.get_download!(download.id)
      assert is_nil(updated.import_failed_at)
    end

    test "does not stomp an existing import_failed_at on subsequent polls" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 5)

      same_bytes = round(50.0 * 1024 * 1024)

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-already-failed-1", "test.nzb",
          size_mb: 100.0,
          mb_left: 50.0
        )
      ])

      media_item = media_item_fixture()

      one_hour_ago = ~U[2026-05-14 10:00:00.000000Z]
      previous_failure_at = ~U[2026-05-14 10:30:00.000000Z]
      now = ~U[2026-05-14 11:00:00.000000Z]

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-already-failed-1",
          last_progress_at: one_hour_ago,
          last_known_bytes: same_bytes,
          import_failed_at: previous_failure_at,
          import_last_error: "stalled after 5m without progress"
        })

      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      updated = Downloads.get_download!(download.id)
      # Pre-existing failure_at must remain — we don't re-flag every poll.
      assert DateTime.diff(updated.import_failed_at, previous_failure_at, :second) == 0
    end

    # Regression for the containment added alongside #278. SABnzbd derives
    # progress as `mb - mbleft` (sabnzbd.ex:534) and parse_size_mb_to_bytes/1
    # does not clamp, so a queue item reporting more left than total — which
    # happens transiently during par2 repair — yields a negative `downloaded`.
    # `StallDetector.evaluate/7` guards on `observed_bytes >= 0`, so that
    # download raises FunctionClauseError before any write is attempted.
    #
    # This is the portable reproduction of the #278 failure shape: one bad
    # download must not abort the reduce and stop stall detection for every
    # other download on the instance.
    test "a download reporting negative bytes doesn't abort the poll for the others" do
      {bypass, client_config} = start_sabnzbd_bypass()

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-negative", "repairing.nzb", size_mb: 100.0, mb_left: 150.0),
        sabnzbd_queue_item("nzo-healthy", "fine.nzb", size_mb: 100.0, mb_left: 40.0)
      ])

      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: client_config.name,
        download_client_id: "nzo-negative",
        last_progress_at: nil,
        last_known_bytes: 0
      })

      healthy =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-healthy",
          last_progress_at: nil,
          last_known_bytes: 0
        })

      now = ~U[2026-05-14 12:00:00.000000Z]

      # Uncontained, the negative download propagates out of Enum.reduce and
      # takes perform/1 with it, so this assertion is what actually fails.
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      # And the healthy download alongside it is still processed, which is the
      # entire point of containing the failure rather than aborting the pass.
      updated = Downloads.get_download!(healthy.id)
      assert updated.last_progress_at == now
      assert updated.last_known_bytes == round(60.0 * 1024 * 1024)
    end
  end

  describe "release blacklist on failure (#123)" do
    test "writes a (indexer, guid) row when a download is reported failed" do
      {bypass, client_config} = start_sabnzbd_bypass()

      mock_sabnzbd_queue(bypass, [],
        history: [
          sabnzbd_history_item("nzo-failed-1", "Show.S01E01.par2_corrupt.nzb", "Failed")
        ]
      )

      media_item = media_item_fixture()

      _download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Show.S01E01.par2_corrupt",
          indexer: "nzbhydra2",
          download_client: client_config.name,
          download_client_id: "nzo-failed-1",
          metadata: %{
            size: 1_000_000_000,
            indexer: "nzbhydra2",
            guid: "stable-guid-123"
          }
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # The (indexer, guid) row must exist and be active.
      assert Mydia.Downloads.Blacklists.blacklisted?("nzbhydra2", "stable-guid-123")
    end

    test "indexer name is normalized to lowercase in the blacklist row" do
      {bypass, client_config} = start_sabnzbd_bypass()

      mock_sabnzbd_queue(bypass, [],
        history: [
          sabnzbd_history_item("nzo-failed-case", "Movie.failed.nzb", "Failed")
        ]
      )

      media_item = media_item_fixture()

      _download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Movie.failed",
          indexer: "Prowlarr",
          download_client: client_config.name,
          download_client_id: "nzo-failed-case",
          metadata: %{
            size: 1_000_000_000,
            indexer: "Prowlarr",
            guid: "case-guid-xyz"
          }
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # Lookup via the original-cased indexer should match — Blacklists normalizes both ways.
      assert Mydia.Downloads.Blacklists.blacklisted?("Prowlarr", "case-guid-xyz")
      assert Mydia.Downloads.Blacklists.blacklisted?("prowlarr", "case-guid-xyz")
    end

    test "does not write a blacklist row when guid is missing" do
      {bypass, client_config} = start_sabnzbd_bypass()

      mock_sabnzbd_queue(bypass, [],
        history: [
          sabnzbd_history_item("nzo-no-guid", "Show.S01E02.nzb", "Failed")
        ]
      )

      media_item = media_item_fixture()

      _download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Show.S01E02",
          indexer: "nzbhydra2",
          download_client: client_config.name,
          download_client_id: "nzo-no-guid",
          # Note: no guid in metadata.
          metadata: %{size: 1_000_000_000, indexer: "nzbhydra2"}
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # Nothing was added.
      assert Mydia.Downloads.Blacklists.list() == []
    end

    test "upserts an existing blacklist row when a release fails again" do
      # The try/rescue in `record_blacklist_entry/2` is the safety net for
      # *unexpected* DB exceptions; testing the exception path requires a
      # mocking library this repo doesn't use (Mox / :meck). The realistic
      # repeat-failure case is covered by `Blacklists.add/4`'s upsert
      # behaviour: when the same `(indexer, guid)` row already exists,
      # the second insert merges via `on_conflict: [set: ...]` rather
      # than raising. This test asserts that path completes cleanly and
      # the failed download is still removed.
      {bypass, client_config} = start_sabnzbd_bypass()

      mock_sabnzbd_queue(bypass, [],
        history: [
          sabnzbd_history_item("nzo-resilient-1", "Show.S01E03.nzb", "Failed")
        ]
      )

      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Show.S01E03",
          indexer: "nzbhydra2",
          download_client: client_config.name,
          download_client_id: "nzo-resilient-1",
          metadata: %{
            size: 1_000_000_000,
            indexer: "nzbhydra2",
            guid: "resilient-guid"
          }
        })

      # Pre-seed the same key so we hit the upsert path.
      {:ok, _} =
        Mydia.Downloads.Blacklists.add(
          "nzbhydra2",
          "resilient-guid",
          "old",
          "stalled"
        )

      assert :ok = perform_job(DownloadMonitor, %{})

      # The download was deleted (downloads table is ephemeral on failure).
      assert_raise Ecto.NoResultsError, fn ->
        Mydia.Downloads.get_download!(download.id)
      end
    end
  end

  describe "pre-completion content rejection" do
    # Transmission reports a torrent's file list as soon as it knows the
    # torrent's metadata (immediately for a direct .torrent add), well before
    # the payload finishes downloading. DownloadMonitor must reject a torrent
    # whose known file list contains no importable video file rather than
    # waiting for it to complete — see the House of the Dragon S03E07/QAsH
    # incident, where a single disguised .exe downloaded to completion every
    # search cycle before the post-completion importer ever saw it.
    # Uses a DB-backed client config (`download_client_config_fixture/1`)
    # rather than `setup_runtime_config/1`. The latter mutates the global
    # `Application.env(:mydia, :runtime_config)`, which races against any
    # other `async: true` test module doing the same (media_import_test.exs
    # does) — usually too narrow a window to matter, but these tests hold it
    # open for a real Bypass HTTP round-trip per poll, which is long enough
    # to lose the race under CI's higher test concurrency. A DB row lives
    # inside this test's own Ecto sandbox transaction, so it can't collide.
    defp start_transmission_bypass(overrides \\ %{}) do
      bypass = Bypass.open()

      client_config =
        download_client_config_fixture(
          Map.merge(%{type: "transmission", host: "localhost", port: bypass.port}, overrides)
        )

      {bypass, client_config}
    end

    defp mock_transmission_torrent_get(bypass, torrents) do
      Bypass.expect(bypass, "POST", "/transmission/rpc", fn conn ->
        case Plug.Conn.get_req_header(conn, "x-transmission-session-id") do
          [] ->
            conn
            |> Plug.Conn.put_resp_header("x-transmission-session-id", "test-session")
            |> Plug.Conn.resp(409, "")

          ["test-session"] ->
            {:ok, body, conn} = Plug.Conn.read_body(conn, length: 1_000_000)
            decoded = Jason.decode!(body)

            case decoded["method"] do
              "torrent-get" ->
                json_resp(conn, 200, %{
                  "result" => "success",
                  "arguments" => %{"torrents" => torrents}
                })

              "torrent-remove" ->
                json_resp(conn, 200, %{"result" => "success", "arguments" => %{}})
            end
        end
      end)
    end

    test "rejects a still-downloading torrent whose only file is a disguised .exe" do
      {bypass, client_config} = start_transmission_bypass()

      torrent = %{
        "hashString" => "qash-hash",
        "name" => "House.of.the.Dragon.S03E07.1080p.AMZN.WEB-DL.DDP5.1.Atmos.H.264-QAsH",
        "status" => 4,
        "percentDone" => 0.05,
        "downloadDir" => "/downloads",
        "files" => [
          %{"name" => "C7466DBA33FE8C5F53F0F80ED8BCFC62242EF310.exe", "length" => 891_885_056}
        ]
      }

      mock_transmission_torrent_get(bypass, [torrent])

      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "House.of.the.Dragon.S03E07.1080p.AMZN.WEB-DL.DDP5.1.Atmos.H.264-QAsH",
          indexer: "1337x",
          download_client: client_config.name,
          download_client_id: "qash-hash",
          metadata: %{
            size: 4_520_571_190,
            indexer: "1337x",
            guid: "https://1337x.to/torrent/6695392/qash/"
          }
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # Rejected before completion: blacklisted, and the row is gone —
      # exactly as if an operator had rejected it from the Issues tab.
      assert Mydia.Downloads.Blacklists.blacklisted?(
               "1337x",
               "https://1337x.to/torrent/6695392/qash/"
             )

      assert_raise Ecto.NoResultsError, fn ->
        Mydia.Downloads.get_download!(download.id)
      end
    end

    test "does not reject a still-downloading torrent that has a video file" do
      {bypass, client_config} = start_transmission_bypass()

      torrent = %{
        "hashString" => "good-hash",
        "name" => "Show.S01E01.1080p.WEB-DL",
        "status" => 4,
        "percentDone" => 0.4,
        "downloadDir" => "/downloads",
        "files" => [
          %{"name" => "Show.S01E01.1080p.WEB-DL.mkv", "length" => 2_000_000_000},
          %{"name" => "Show.S01E01.1080p.WEB-DL.nfo", "length" => 2_048}
        ]
      }

      mock_transmission_torrent_get(bypass, [torrent])

      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Show.S01E01.1080p.WEB-DL",
          indexer: "1337x",
          download_client: client_config.name,
          download_client_id: "good-hash",
          metadata: %{size: 2_000_000_000, indexer: "1337x", guid: "guid-good"}
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      refute Mydia.Downloads.Blacklists.blacklisted?("1337x", "guid-good")
      assert Mydia.Downloads.get_download!(download.id)
    end

    test "does not reject a torrent whose file list is not yet known" do
      {bypass, client_config} = start_transmission_bypass()

      torrent = %{
        "hashString" => "pending-hash",
        "name" => "Show.S01E02.1080p.WEB-DL",
        "status" => 4,
        "percentDone" => 0.0,
        "downloadDir" => "/downloads"
        # No "files" key — metadata not resolved yet (e.g. a fresh magnet).
      }

      mock_transmission_torrent_get(bypass, [torrent])

      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Show.S01E02.1080p.WEB-DL",
          indexer: "1337x",
          download_client: client_config.name,
          download_client_id: "pending-hash",
          metadata: %{size: 2_000_000_000, indexer: "1337x", guid: "guid-pending"}
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      refute Mydia.Downloads.Blacklists.blacklisted?("1337x", "guid-pending")
      assert Mydia.Downloads.get_download!(download.id)
    end

    # The regression tests below drive a real qBittorrent adapter rather than
    # Transmission, because the bug lived entirely in qBittorrent's shape:
    # `parse_torrent_status/1` reports `files: [content_path]`, and
    # `content_path` is the torrent's root DIRECTORY for a multi-file torrent.
    # A Transmission fixture cannot express that, so a Transmission-based test
    # here would pass both before and after the fix and prove nothing.
    defp start_qbittorrent_bypass(overrides \\ %{}) do
      bypass = Bypass.open()

      client_config =
        download_client_config_fixture(
          Map.merge(%{type: "qbittorrent", host: "localhost", port: bypass.port}, overrides)
        )

      Bypass.stub(bypass, "POST", "/api/v2/auth/login", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("set-cookie", "SID=test-sid; HttpOnly")
        |> Plug.Conn.resp(200, "Ok.")
      end)

      # reject_release/2 removes the torrent from the client; stub it so the
      # rejection path can complete instead of erroring on an unknown route.
      Bypass.stub(bypass, "POST", "/api/v2/torrents/delete", fn conn ->
        Plug.Conn.resp(conn, 200, "")
      end)

      {bypass, client_config}
    end

    defp mock_qbittorrent(bypass, torrents, files) do
      Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
        json_resp(conn, 200, torrents)
      end)

      Bypass.stub(bypass, "GET", "/api/v2/torrents/files", fn conn ->
        json_resp(conn, 200, files)
      end)
    end

    defp qbittorrent_torrent(hash, name) do
      %{
        "hash" => hash,
        "name" => name,
        "state" => "downloading",
        "progress" => 0.42,
        "save_path" => "/downloads",
        # The whole bug in one field: the root folder, not a file.
        "content_path" => "/downloads/#{name}"
      }
    end

    test "keeps a qBittorrent torrent whose content_path is the release folder" do
      {bypass, client_config} = start_qbittorrent_bypass()

      # `Path.extname("Minions.Monsters.2026.720p.WEBRip.x264-YTS")` is
      # ".x264-YTS", which is not a video extension, so judging the torrent
      # from `content_path` destroyed it mid-download. The real enumeration
      # below holds an .mkv, so it must survive.
      name = "Minions.Monsters.2026.720p.WEBRip.x264-YTS"

      mock_qbittorrent(
        bypass,
        [qbittorrent_torrent("folder-hash", name)],
        [%{"name" => "#{name}/movie.mkv", "size" => 1}]
      )

      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: name,
          indexer: "1337x",
          download_client: client_config.name,
          download_client_id: "folder-hash",
          metadata: %{indexer: "1337x", guid: "guid-folder"}
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # Still there, still ours, not blacklisted.
      assert Mydia.Downloads.get_download!(download.id)
      refute Mydia.Downloads.Blacklists.blacklisted?("1337x", "guid-folder")
    end

    test "still rejects a qBittorrent torrent whose enumeration holds no video" do
      # The other half of the regression: gating on a real enumeration must
      # not cost qBittorrent users the malware protection this check exists
      # for. Same directory-shaped content_path, genuinely bad contents.
      {bypass, client_config} = start_qbittorrent_bypass()

      name = "Some.Movie.2026.720p.WEBRip"

      mock_qbittorrent(
        bypass,
        [qbittorrent_torrent("exe-hash", name)],
        [%{"name" => "#{name}/payload.exe", "size" => 1}]
      )

      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        title: name,
        indexer: "1337x",
        download_client: client_config.name,
        download_client_id: "exe-hash",
        metadata: %{indexer: "1337x", guid: "guid-exe"}
      })

      assert :ok = perform_job(DownloadMonitor, %{})

      assert Mydia.Downloads.Blacklists.blacklisted?("1337x", "guid-exe")
    end

    test "stamps content_checked_at so the enumeration runs only once" do
      {bypass, client_config} = start_transmission_bypass()

      torrent = %{
        "hashString" => "once-hash",
        "name" => "Some.Movie.2026.720p",
        "status" => 4,
        "percentDone" => 0.42,
        "downloadDir" => "/downloads",
        "files" => [%{"name" => "Some.Movie.2026.720p/movie.mkv", "length" => 1}]
      }

      mock_transmission_torrent_get(bypass, [torrent])

      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Some.Movie.2026.720p",
          indexer: "1337x",
          download_client: client_config.name,
          download_client_id: "once-hash",
          metadata: %{indexer: "1337x", guid: "guid-once"}
        })

      assert :ok = perform_job(DownloadMonitor, %{})
      assert Mydia.Downloads.get_download!(download.id).content_checked_at
    end

    test "does not reject when the client reports no files yet" do
      {bypass, client_config} = start_transmission_bypass()

      torrent = %{
        "hashString" => "empty-hash",
        "name" => "Some.Movie.2026.720p",
        "status" => 4,
        "percentDone" => 0.0,
        "downloadDir" => "/downloads",
        "files" => []
      }

      mock_transmission_torrent_get(bypass, [torrent])

      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Some.Movie.2026.720p",
          indexer: "1337x",
          download_client: client_config.name,
          download_client_id: "empty-hash",
          metadata: %{indexer: "1337x", guid: "guid-empty"}
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      assert Mydia.Downloads.get_download!(download.id)
      refute Mydia.Downloads.Blacklists.blacklisted?("1337x", "guid-empty")
      # An empty enumeration means "metadata not resolved yet", so we must be
      # willing to look again on the next poll.
      refute Mydia.Downloads.get_download!(download.id).content_checked_at
    end

    test "stops auto-rejecting a media item after the configured limit" do
      {bypass, client_config} = start_transmission_bypass()
      media_item = media_item_fixture()

      # Pre-load the counter to the default limit of 3.
      for _ <- 1..3 do
        Mydia.Search.record_failure("auto_reject", media_item.id, "no_importable_files")
      end

      torrent = %{
        "hashString" => "capped-hash",
        "name" => "Some.Movie.2026.720p",
        "status" => 4,
        "percentDone" => 0.42,
        "downloadDir" => "/downloads",
        "files" => [%{"name" => "Some.Movie.2026.720p/payload.exe", "length" => 1}]
      }

      mock_transmission_torrent_get(bypass, [torrent])

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          title: "Some.Movie.2026.720p",
          indexer: "1337x",
          download_client: client_config.name,
          download_client_id: "capped-hash",
          metadata: %{indexer: "1337x", guid: "guid-capped"}
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # Suppressed: torrent untouched, release not blacklisted.
      reloaded = Mydia.Downloads.get_download!(download.id)
      refute Mydia.Downloads.Blacklists.blacklisted?("1337x", "guid-capped")

      # Left non-terminal so it can still complete and import normally.
      refute reloaded.import_failed_at
      refute reloaded.import_failure_reason
    end

    test "still rejects while under the limit, and counts the rejection" do
      {bypass, client_config} = start_transmission_bypass()
      media_item = media_item_fixture()

      torrent = %{
        "hashString" => "under-hash",
        "name" => "Some.Movie.2026.720p",
        "status" => 4,
        "percentDone" => 0.42,
        "downloadDir" => "/downloads",
        "files" => [%{"name" => "Some.Movie.2026.720p/payload.exe", "length" => 1}]
      }

      mock_transmission_torrent_get(bypass, [torrent])

      download_fixture(%{
        media_item_id: media_item.id,
        title: "Some.Movie.2026.720p",
        indexer: "1337x",
        download_client: client_config.name,
        download_client_id: "under-hash",
        metadata: %{indexer: "1337x", guid: "guid-under"}
      })

      assert :ok = perform_job(DownloadMonitor, %{})

      assert Mydia.Downloads.Blacklists.blacklisted?("1337x", "guid-under")
      assert %{failure_count: 1} = Mydia.Search.get_backoff_info("auto_reject", media_item.id)
    end
  end

  describe "handle_failure/1 with a classified debrid failure" do
    setup do
      alias Mydia.Downloads.Client.Debrid.StubProvider

      StubProvider.ensure_started!()
      StubProvider.reset()
      on_exit(fn -> StubProvider.reset() end)

      ensure_started!(
        {Registry, [keys: :unique, name: Mydia.Downloads.Client.Debrid.FetcherRegistry]}
      )

      ensure_started!(
        {DynamicSupervisor,
         [name: Mydia.Downloads.Client.Debrid.FetcherSupervisor, strategy: :one_for_one]}
      )

      ensure_started!(Mydia.Downloads.Client.Debrid.RateLimiter)

      prior = Application.get_env(:mydia, :debrid_provider_overrides, %{})

      Application.put_env(:mydia, :debrid_provider_overrides, %{
        "tor_box" => StubProvider
      })

      on_exit(fn -> Application.put_env(:mydia, :debrid_provider_overrides, prior) end)

      :ok
    end

    test "blacklists under the category slug and records the native detail" do
      alias Mydia.Downloads.Blacklists
      alias Mydia.Downloads.Client.Debrid.{ProviderJob, StubProvider}

      setup_runtime_config([
        build_test_client_config(%{
          name: "my-debrid",
          type: :debrid,
          api_key: "tb-key",
          connection_settings: %{"provider" => "tor_box"}
        })
      ])

      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "my-debrid",
          download_client_id: "job-1",
          indexer: "prowlarr",
          metadata: %{"guid" => "guid-1"}
        })

      StubProvider.set(
        :list_jobs,
        {:ok,
         %{
           "job-1" => %ProviderJob{
             provider_id: "job-1",
             state: :error,
             progress: 0.0,
             name: "Some.Release.1080p",
             total_bytes: 1000,
             files: [],
             hoster_links: [],
             raw_status: %{},
             failure_category: :missing_files,
             failure_detail: "missingFiles"
           }
         }}
      )

      assert :ok = perform_job(DownloadMonitor, %{})

      # The download row is ephemeral and deleted on failure.
      assert_raise Ecto.NoResultsError, fn -> Downloads.get_download!(download.id) end

      assert [row] = Blacklists.list(failure_reason: "missing_files")
      assert row.guid == "guid-1"
      assert row.indexer == "prowlarr"

      # The composed operator message is what the activity feed and the
      # media-item history render (Events.download_failed/3 stores it under
      # metadata["error_message"] — see lib/mydia/events.ex:593). Assert on
      # the exact composed sentence, not just substring membership, so a
      # transposed argument at the FailureCategory.message/3 call site
      # (e.g. swapping client and detail) would fail this test even though
      # each individual value still appears somewhere in the string.
      Process.sleep(100)

      assert [event] = Events.list_events(type: "download.failed")
      message = event.metadata["error_message"]

      assert message == "my-debrid reported missing files: missingFiles"

      # The event and the blacklist row must carry the identical slug, so the
      # activity feed and the admin blacklist page can be filtered on one
      # vocabulary (#237). `handle_failure/1` binds the slug once and passes
      # the same value to both.
      assert event.metadata["failure_category"] == "missing_files"
      assert event.metadata["failure_category"] == row.failure_reason
      assert event.metadata["failure_detail"] == "missingFiles"
    end

    test "an unclassified failure still uses the pre-existing fallback slug" do
      alias Mydia.Downloads.Blacklists
      alias Mydia.Downloads.Client.Debrid.{ProviderJob, StubProvider}

      setup_runtime_config([
        build_test_client_config(%{
          name: "my-debrid",
          type: :debrid,
          api_key: "tb-key",
          connection_settings: %{"provider" => "tor_box"}
        })
      ])

      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "my-debrid",
        download_client_id: "job-2",
        indexer: "prowlarr",
        metadata: %{"guid" => "guid-2"}
      })

      StubProvider.set(
        :list_jobs,
        {:ok,
         %{
           "job-2" => %ProviderJob{
             provider_id: "job-2",
             state: :error,
             progress: 0.0,
             name: "Other.Release.1080p",
             total_bytes: 1000,
             files: [],
             hoster_links: [],
             raw_status: %{},
             failure_category: nil,
             failure_detail: nil
           }
         }}
      )

      assert :ok = perform_job(DownloadMonitor, %{})

      assert [row] = Blacklists.list(failure_reason: "client_reported_failure")
      assert row.guid == "guid-2"
    end

    test "client failure detail does not leak into error_message during enrichment" do
      # Guards DownloadMonitor's unhandled-failure filter (download_monitor.ex:91).
      # If error_message ever falls back to client detail, failed downloads look
      # already-handled and stop being processed entirely — silently.
      alias Mydia.Downloads.Client.Debrid.{ProviderJob, StubProvider}

      setup_runtime_config([
        build_test_client_config(%{
          name: "my-debrid",
          type: :debrid,
          api_key: "tb-key",
          connection_settings: %{"provider" => "tor_box"}
        })
      ])

      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "my-debrid",
        download_client_id: "job-3",
        indexer: "prowlarr",
        metadata: %{"guid" => "guid-3"}
      })

      StubProvider.set(
        :list_jobs,
        {:ok,
         %{
           "job-3" => %ProviderJob{
             provider_id: "job-3",
             state: :error,
             progress: 0.0,
             name: "Some.Release.1080p",
             total_bytes: 1000,
             files: [],
             hoster_links: [],
             raw_status: %{},
             failure_category: :missing_files,
             failure_detail: "missingFiles"
           }
         }}
      )

      assert [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.status == "failed"
      assert enriched.error_message == nil
      assert enriched.client_failure_category == :missing_files
      assert enriched.client_error_detail == "missingFiles"
    end
  end

  # Acceptance examples carried from the stall-resilience plan. AE1 (outage
  # recovery) and AE3 (genuine soft-stall) are additionally exercised by the
  # "stall detection" describe block and AE7 below; here we lock the multi-poll
  # sequences and the end-to-end incident replay.
  describe "acceptance examples (AE1–AE7)" do
    test "AE7: pegasus incident replay — outage then recovery never terminally fails" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 60)

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-pegasus", "show.nzb", size_mb: 100.0, mb_left: 50.0)
      ])

      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-pegasus",
          last_progress_at: nil,
          last_known_bytes: 0
        })

      t0 = ~U[2026-06-16 00:00:00.000000Z]

      # Poll 1: first observation initializes tracking.
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(t0)})
      after1 = Downloads.get_download!(download.id)
      assert after1.last_progress_at == t0
      assert after1.last_observed_at == t0

      # Outage: client unreachable for hours. The download reads as "unknown",
      # is excluded from stall tracking, and last_observed_at stays frozen.
      Bypass.down(bypass)
      during = DateTime.add(t0, 5 * 60 * 60, :second)
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(during)})
      mid = Downloads.get_download!(download.id)
      assert is_nil(mid.import_failed_at)
      assert is_nil(mid.stalled_since)
      assert mid.last_observed_at == t0

      # Recovery ~10h after t0, same byte count. The observation gap (~10h) far
      # exceeds the threshold → reset, NOT a stall.
      Bypass.up(bypass)
      recovery = DateTime.add(t0, 10 * 60 * 60, :second)
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(recovery)})
      recovered = Downloads.get_download!(download.id)
      assert is_nil(recovered.import_failed_at)
      assert is_nil(recovered.stalled_since)
      assert recovered.last_progress_at == recovery
      assert recovered.last_observed_at == recovery

      # A follow-up poll shortly after recovery, still same bytes — fresh grace
      # window, so still not stalled.
      followup = DateTime.add(recovery, 120, :second)
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(followup)})
      after_followup = Downloads.get_download!(download.id)
      assert is_nil(after_followup.import_failed_at)
      assert is_nil(after_followup.stalled_since)

      # Episode never released: the download still occupies it throughout.
      assert download.id in occupying_ids()

      Process.sleep(100)
      assert Events.list_events(type: "download.failed") == []
    end

    test "AE2: restart with a stale last_observed_at resets rather than false-stalls" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 60)
      same_bytes = round(50.0 * 1024 * 1024)

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-ae2", "show.nzb", size_mb: 100.0, mb_left: 50.0)
      ])

      media_item = media_item_fixture()

      # last_observed_at is 2h old (2× grace) — the downtime gap resets the clock.
      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-ae2",
          last_progress_at: ~U[2026-06-16 00:00:00.000000Z],
          last_known_bytes: same_bytes,
          last_observed_at: ~U[2026-06-16 00:00:00.000000Z]
        })

      now = ~U[2026-06-16 02:00:00.000000Z]
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      updated = Downloads.get_download!(download.id)
      assert is_nil(updated.import_failed_at)
      assert is_nil(updated.stalled_since)
      assert updated.last_progress_at == now
      assert updated.last_observed_at == now
    end

    test "AE4: soft-stall auto-clears on resumed progress; episode never released" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 60)

      # Client now reports MORE bytes (30 MB left vs the 50 MB baseline).
      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-ae4", "show.nzb", size_mb: 100.0, mb_left: 30.0)
      ])

      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-ae4",
          last_progress_at: ~U[2026-06-16 00:00:00.000000Z],
          last_known_bytes: round(50.0 * 1024 * 1024),
          last_observed_at: ~U[2026-06-16 00:58:00.000000Z],
          stalled_since: ~U[2026-06-16 00:50:00.000000Z]
        })

      now = ~U[2026-06-16 01:00:00.000000Z]
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      updated = Downloads.get_download!(download.id)
      assert is_nil(updated.stalled_since)
      assert is_nil(updated.import_failed_at)
      assert updated.last_known_bytes == round(70.0 * 1024 * 1024)
      assert download.id in occupying_ids()

      Process.sleep(100)
      assert Events.list_events(type: "download.unstalled") != []
      assert Events.list_events(type: "download.failed") == []
    end

    test "a soft-stall cleared by an observation-gap reset emits a recovery event" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 60)

      # Same byte count as the baseline — recovery here comes from the gap reset,
      # not from progress.
      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-reset-recover", "show.nzb", size_mb: 100.0, mb_left: 50.0)
      ])

      media_item = media_item_fixture()

      # Soft-stalled, but last_observed_at is ~10h stale (outage/restart), so the
      # next poll takes the gap-reset branch and clears the soft-stall.
      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-reset-recover",
          last_progress_at: ~U[2026-06-16 00:00:00.000000Z],
          last_known_bytes: round(50.0 * 1024 * 1024),
          last_observed_at: ~U[2026-06-16 00:00:00.000000Z],
          stalled_since: ~U[2026-06-16 01:00:00.000000Z]
        })

      now = ~U[2026-06-16 10:00:00.000000Z]
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      updated = Downloads.get_download!(download.id)
      assert is_nil(updated.stalled_since)
      assert is_nil(updated.import_failed_at)
      assert updated.last_progress_at == now
      assert download.id in occupying_ids()

      Process.sleep(100)
      assert Events.list_events(type: "download.unstalled") != []
      assert Events.list_events(type: "download.failed") == []
    end

    test "AE5: a paused download past the grace window never stalls" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 60)

      paused_slot =
        "nzo-ae5"
        |> sabnzbd_queue_item("show.nzb", size_mb: 100.0, mb_left: 50.0)
        |> Map.put("status", "Paused")

      mock_sabnzbd_queue(bypass, [paused_slot])

      media_item = media_item_fixture()

      stale_observed = ~U[2026-06-16 04:58:00.000000Z]

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-ae5",
          # last_progress_at 5h ago — far past grace, but the torrent is paused.
          last_progress_at: ~U[2026-06-16 00:00:00.000000Z],
          last_known_bytes: round(50.0 * 1024 * 1024),
          last_observed_at: stale_observed
        })

      now = ~U[2026-06-16 05:00:00.000000Z]
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      updated = Downloads.get_download!(download.id)
      assert is_nil(updated.import_failed_at)
      assert is_nil(updated.stalled_since)
      # Paused → excluded from the active set → last_observed_at is not advanced.
      assert updated.last_observed_at == stale_observed
    end

    test "AE6: a soft-stall past the escalation threshold is given up on entirely" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 60)
      same_bytes = round(50.0 * 1024 * 1024)

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-ae6", "show.nzb", size_mb: 100.0, mb_left: 50.0)
      ])

      media_item = media_item_fixture(%{type: "movie"})

      # Escalation threshold = grace × 3 = 180 min. stalled_since is 182 min old,
      # observed continuously (recent last_observed_at), bytes unchanged.
      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-ae6",
          indexer: "1337x",
          metadata: %{"guid" => "ae6-guid"},
          last_progress_at: ~U[2026-06-16 00:00:00.000000Z],
          last_known_bytes: same_bytes,
          last_observed_at: ~U[2026-06-16 03:58:00.000000Z],
          stalled_since: ~U[2026-06-16 00:58:00.000000Z]
        })

      now = ~U[2026-06-16 04:00:00.000000Z]
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      # The row is gone, not annotated. That is the whole point: a give-up that
      # leaves the download sitting in the queue is what confused operators.
      refute Repo.get(Download, download.id)
      refute download.id in occupying_ids()

      # Blacklisted briefly, so the replacement search cannot re-grab the same
      # dead release, but a swarm that recovers overnight becomes available again.
      assert Blacklists.blacklisted?("1337x", "ae6-guid")
      row = Repo.get_by!(ReleaseBlacklist, indexer: "1337x", guid: "ae6-guid")
      assert row.failure_reason == "stalled"
      expected_expiry = DateTime.add(DateTime.utc_now(), 24 * 60 * 60, :second)
      assert abs(DateTime.diff(row.expires_at, expected_expiry, :second)) < 60

      assert_enqueued(
        worker: Mydia.Jobs.MovieSearch,
        args: %{"mode" => "specific", "media_item_id" => media_item.id}
      )

      Process.sleep(100)
      # One event, not two: the stall path owns its own download.failed and
      # suppresses reject_release/2's download.cancelled.
      assert [event] = Events.list_events(type: "download.failed")
      assert event.metadata["failure_category"] == "stalled"
      assert event.metadata["error_message"] =~ "no progress for 4h"
      assert Events.list_events(type: "download.cancelled") == []
    end

    test "AE6b: an exhausted auto-reject cap leaves the stalled download alone" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 60)
      same_bytes = round(50.0 * 1024 * 1024)

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-ae6b", "show.nzb", size_mb: 100.0, mb_left: 50.0)
      ])

      media_item = media_item_fixture(%{type: "movie"})

      # Burn the cap (default limit is 3) before the poll runs.
      for _ <- 1..3 do
        Mydia.Search.record_failure("auto_reject", media_item.id, "stalled")
      end

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-ae6b",
          indexer: "1337x",
          metadata: %{"guid" => "ae6b-guid"},
          last_progress_at: ~U[2026-06-16 00:00:00.000000Z],
          last_known_bytes: same_bytes,
          last_observed_at: ~U[2026-06-16 03:58:00.000000Z],
          stalled_since: ~U[2026-06-16 00:58:00.000000Z]
        })

      now = ~U[2026-06-16 04:00:00.000000Z]
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      # When the cap trips, the likeliest truth is that our detector is wrong,
      # so the download is left to finish rather than destroyed.
      suppressed = Repo.get(Download, download.id)
      assert suppressed
      refute Blacklists.blacklisted?("1337x", "ae6b-guid")

      # The stall clock is reset so the decision is not re-announced on every
      # poll. Without this the download stays past the escalation threshold and
      # each poll re-emits the suppression event.
      assert is_nil(suppressed.stalled_since)
      assert suppressed.last_progress_at

      Process.sleep(100)
      assert Events.list_events(type: "download.failed") == []
      assert length(Events.list_events(type: "download.auto_reject_suppressed")) == 1
    end

    test "AE6d: a suppressed stall is not re-announced on the next poll" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 60)
      same_bytes = round(50.0 * 1024 * 1024)

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-ae6d", "show.nzb", size_mb: 100.0, mb_left: 50.0)
      ])

      media_item = media_item_fixture(%{type: "movie"})

      for _ <- 1..3 do
        Mydia.Search.record_failure("auto_reject", media_item.id, "stalled")
      end

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-ae6d",
          indexer: "1337x",
          metadata: %{"guid" => "ae6d-guid"},
          last_progress_at: ~U[2026-06-16 00:00:00.000000Z],
          last_known_bytes: same_bytes,
          last_observed_at: ~U[2026-06-16 03:58:00.000000Z],
          stalled_since: ~U[2026-06-16 00:58:00.000000Z]
        })

      first = ~U[2026-06-16 04:00:00.000000Z]
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(first)})

      # One poll later, well inside the fresh grace window the reset bought.
      second = DateTime.add(first, 120, :second)
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(second)})

      assert Repo.get(Download, download.id)

      Process.sleep(100)
      assert length(Events.list_events(type: "download.auto_reject_suppressed")) == 1
    end

    test "AE6c: a stalled download with no blacklist key is still cleared" do
      {bypass, client_config} = start_sabnzbd_bypass(incomplete_grace_minutes: 60)
      same_bytes = round(50.0 * 1024 * 1024)

      mock_sabnzbd_queue(bypass, [
        sabnzbd_queue_item("nzo-ae6c", "show.nzb", size_mb: 100.0, mb_left: 50.0)
      ])

      media_item = media_item_fixture(%{type: "movie"})

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: client_config.name,
          download_client_id: "nzo-ae6c",
          indexer: nil,
          metadata: %{},
          last_progress_at: ~U[2026-06-16 00:00:00.000000Z],
          last_known_bytes: same_bytes,
          last_observed_at: ~U[2026-06-16 03:58:00.000000Z],
          stalled_since: ~U[2026-06-16 00:58:00.000000Z]
        })

      now = ~U[2026-06-16 04:00:00.000000Z]
      assert :ok = perform_job(DownloadMonitor, %{"now" => DateTime.to_iso8601(now)})

      refute Repo.get(Download, download.id)
      assert Repo.aggregate(ReleaseBlacklist, :count) == 0
    end
  end

  ## Helper Functions

  defp ensure_started!(child_spec) do
    case start_supervised(child_spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, :already_started} -> :ok
    end
  end

  defp occupying_ids do
    Download.occupying() |> Repo.all() |> Enum.map(& &1.id)
  end

  # Backdates `inserted_at` directly — the changeset doesn't cast timestamps,
  # so this is the only way to simulate an old grab. Mirrors `backdate/2` in
  # history_grab_status_test.exs.
  defp backdate(download, minutes_ago) do
    cutoff = DateTime.add(DateTime.utc_now(), -minutes_ago * 60, :second)

    from(d in Download, where: d.id == ^download.id)
    |> Repo.update_all(set: [inserted_at: cutoff])

    download
  end

  defp start_sabnzbd_bypass(opts \\ []) do
    bypass = Bypass.open()
    grace = Keyword.get(opts, :incomplete_grace_minutes, 60)

    {:ok, client_config} =
      Mydia.Settings.create_download_client_config(%{
        name: "SABnzbd-StallTest-#{System.unique_integer([:positive])}",
        type: :sabnzbd,
        host: "localhost",
        port: bypass.port,
        api_key: "test-api-key",
        enabled: true,
        priority: 1,
        incomplete_grace_minutes: grace
      })

    {bypass, client_config}
  end

  defp mock_sabnzbd_queue(bypass, queue_slots, opts \\ []) do
    history_slots = Keyword.get(opts, :history, [])

    Bypass.expect(bypass, "GET", "/api", fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)

      case conn.query_params["mode"] do
        "queue" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{"queue" => %{"slots" => queue_slots}}))

        "history" ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(
            200,
            Jason.encode!(%{"history" => %{"slots" => history_slots}})
          )

        _other ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.resp(200, Jason.encode!(%{}))
      end
    end)
  end

  defp sabnzbd_queue_item(nzo_id, filename, opts) do
    size_mb = Keyword.fetch!(opts, :size_mb)
    mb_left = Keyword.fetch!(opts, :mb_left)

    %{
      "nzo_id" => nzo_id,
      "filename" => filename,
      "status" => "Downloading",
      "mb" => size_mb,
      "mbleft" => mb_left,
      "kbpersec" => 0.0,
      "timeleft" => "0:00:00",
      "storage" => "/downloads",
      "added" => System.system_time(:second)
    }
  end

  defp sabnzbd_history_item(nzo_id, filename, status) do
    %{
      "nzo_id" => nzo_id,
      "filename" => filename,
      "status" => status,
      "bytes" => 1_000_000,
      "storage" => "/downloads",
      "completed" => System.system_time(:second)
    }
  end

  defp setup_runtime_config(download_clients) do
    config = %Mydia.Config.Schema{
      server: %Mydia.Config.Schema.Server{},
      database: %Mydia.Config.Schema.Database{},
      auth: %Mydia.Config.Schema.Auth{},
      media: %Mydia.Config.Schema.Media{},
      downloads: %Mydia.Config.Schema.Downloads{},
      logging: %Mydia.Config.Schema.Logging{},
      oban: %Mydia.Config.Schema.Oban{},
      download_clients: download_clients
    }

    # Capture and restore the prior value. `:runtime_config` is global
    # Application state (test_helper.exs forces empty download_clients at boot);
    # leaving an enabled client here leaks into later tests, e.g. DownloadsLive,
    # whose queue-tab filter then hides the completed downloads they seed.
    previous = Application.get_env(:mydia, :runtime_config)
    Application.put_env(:mydia, :runtime_config, config)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :runtime_config)
        value -> Application.put_env(:mydia, :runtime_config, value)
      end
    end)
  end

  defp build_test_client_config(overrides \\ %{}) do
    defaults = %{
      name: "TestClient",
      type: :qbittorrent,
      enabled: true,
      priority: 1,
      host: "localhost",
      port: 8080,
      username: "admin",
      password: "admin",
      use_ssl: false,
      url_base: nil,
      category: nil,
      download_directory: nil
    }

    struct!(Mydia.Config.Schema.DownloadClient, Map.merge(defaults, overrides))
  end

  defp stub_qbit_login(bypass) do
    Bypass.stub(bypass, "POST", "/api/v2/auth/login", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "SID=test-sid; HttpOnly")
      |> Plug.Conn.resp(200, "Ok.")
    end)
  end

  defp json_resp(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(body))
  end
end
