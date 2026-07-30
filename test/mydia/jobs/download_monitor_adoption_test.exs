defmodule Mydia.Jobs.DownloadMonitorAdoptionTest do
  @moduledoc """
  Covers the two halves of the orphan path: adoption onto a renamed client,
  and honest messaging for orphans that cannot be adopted.

  These tests do not stub a live client, so no adoption candidate is ever
  found here; adoption itself is unit-tested in
  `Mydia.Downloads.ClientAdoptionTest`. What this file guards is the message
  and the persisted tag, which is what the Issues tab groups on.
  """
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Downloads
  alias Mydia.Downloads.Structs.EnrichedDownload
  alias Mydia.Jobs.DownloadMonitor

  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures

  describe "orphaned downloads" do
    test "explains that a removed client is gone, and tags the row" do
      setup_runtime_config([client_config(%{name: "kept"})])
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "qbit-old",
          download_client_id: "hash-a"
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      updated = Downloads.get_download!(download.id)

      assert updated.error_message =~ "no longer configured in Mydia"
      assert updated.error_message =~ "qbit-old"
      refute updated.error_message =~ "Removed from download client"
      assert updated.import_failure_reason == "no_client"
    end

    test "explains that a disabled client is disabled, not removed" do
      setup_runtime_config([
        client_config(%{name: "kept"}),
        client_config(%{name: "qbit-paused", enabled: false})
      ])

      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "qbit-paused",
          download_client_id: "hash-b"
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      updated = Downloads.get_download!(download.id)

      assert updated.error_message =~ "is disabled in Mydia"
      refute updated.error_message =~ "no longer configured"
      assert updated.import_failure_reason == "no_client"
    end

    test "releases the target so the media can be searched again" do
      setup_runtime_config([client_config(%{name: "kept"})])
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "qbit-old",
          download_client_id: "hash-c"
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      # `Download.occupying/1` excludes rows with a non-nil error_message, so
      # writing the message is what frees the episode for a fresh search.
      occupying_ids =
        Mydia.Downloads.Download
        |> Mydia.Downloads.Download.occupying()
        |> Mydia.Repo.all()
        |> Enum.map(& &1.id)

      refute download.id in occupying_ids
    end

    test "does not blacklist the release" do
      setup_runtime_config([client_config(%{name: "kept"})])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "qbit-old",
        download_client_id: "hash-d",
        indexer: "test-indexer",
        metadata: %{"guid" => "guid-1", "indexer" => "test-indexer"}
      })

      assert :ok = perform_job(DownloadMonitor, %{})

      # The release never failed. The client left. Blacklisting here would
      # poison future searches for a perfectly good release.
      assert Mydia.Repo.aggregate(Mydia.Downloads.ReleaseBlacklist, :count) == 0
    end

    test "tags a legacy orphan the previous release already marked" do
      # Rows the released code marked with "Removed from download client ..."
      # carry an error_message, and the monitor's `missing` filter requires a
      # nil one, so they can never re-enter `handle_missing/1` to be tagged.
      # Without a backfill the operator who upgrades with 50 falsely blamed
      # orphans, which is who this feature is for, sees no banner at all.
      setup_runtime_config([client_config(%{name: "kept"})])
      media_item = media_item_fixture()

      legacy_message =
        "Removed from download client 'qbit-old' before import completed. " <>
          "The download may have been manually deleted, or the client may have " <>
          "encountered an error."

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "qbit-old",
          download_client_id: "hash-legacy",
          error_message: legacy_message,
          import_failure_reason: nil
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      updated = Downloads.get_download!(download.id)

      assert updated.import_failure_reason == "no_client"
      # Tag only: the message is left exactly as the old release wrote it.
      assert updated.error_message == legacy_message

      assert Downloads.removed_client_groups() == [
               %{download_client: "qbit-old", count: 1}
             ]
    end

    test "leaves an unrelated failure message untagged" do
      # The backfill keys on the old release's exact copy. Any other failure
      # message means some other subsystem owns this row, and mis-tagging it
      # would offer the operator a bulk delete for a download whose client is
      # not the problem.
      setup_runtime_config([client_config(%{name: "kept"})])
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "qbit-old",
          download_client_id: "hash-unrelated",
          error_message: "Grab timed out",
          import_failure_reason: nil
        })

      assert :ok = perform_job(DownloadMonitor, %{})

      updated = Downloads.get_download!(download.id)

      assert updated.import_failure_reason == nil
      assert Downloads.removed_client_groups() == []
    end

    test "keeps the original copy when a configured client dropped the torrent" do
      # A download whose client IS configured classifies as :present, so it
      # must keep the original message. Without this guard, step 6 of the
      # migration leaves that branch entirely uncovered: every other test in
      # the suite now exercises the :removed path.
      present =
        EnrichedDownload.new(%{
          id: "d-present",
          title: "Some.Release",
          download_client: "kept",
          status: "missing",
          client_config_state: :present
        })

      removed = %{present | client_config_state: :removed, download_client: "gone"}

      assert DownloadMonitor.missing_error_message(present) =~
               "Removed from download client 'kept'"

      assert DownloadMonitor.missing_error_message(removed) =~
               "no longer configured in Mydia"
    end
  end

  defp client_config(overrides) do
    Enum.into(overrides, %{
      name: "TestClient",
      type: :qbittorrent,
      enabled: true,
      host: "localhost",
      port: 8080,
      use_ssl: false,
      username: "admin",
      password: "admin",
      priority: 1
    })
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

    previous = Application.get_env(:mydia, :runtime_config)
    Application.put_env(:mydia, :runtime_config, config)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:mydia, :runtime_config)
        value -> Application.put_env(:mydia, :runtime_config, value)
      end
    end)
  end
end
