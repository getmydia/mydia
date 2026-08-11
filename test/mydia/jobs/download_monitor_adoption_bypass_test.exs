defmodule Mydia.Jobs.DownloadMonitorAdoptionBypassTest do
  @moduledoc """
  The adoption success path, end to end.

  A download references 'qbit-old', which no longer exists. A configured,
  reachable client named 'qbit-new' holds the same info hash. One monitor pass
  must re-point the download at 'qbit-new' and clear the orphan error state
  written by an earlier pass, so a row parked in the Issues tab comes back to
  life when the operator re-adds their client.

  The same file covers the symmetric case: the download's *own* client coming
  back, by being re-enabled or re-added under the same name. That heals through
  the same writer, because a row that only ever heals when some *other* client
  claims it would keep a false error message forever on the commonest recovery
  path there is.
  """
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.Downloads
  alias Mydia.Jobs.DownloadMonitor

  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures

  @hash "1234567890abcdef1234567890abcdef12345678"

  setup do
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/api/v2/auth/login", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "SID=test-sid; HttpOnly")
      |> Plug.Conn.resp(200, "Ok.")
    end)

    Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!([torrent_payload(@hash)]))
    end)

    # DownloadMonitor's pre-completion content check calls list_files/2, which
    # hits /torrents/files after /torrents/info. Stub it so healthy torrents
    # are not treated as unknown and so Bypass does not see an unexpected route.
    Bypass.stub(bypass, "GET", "/api/v2/torrents/files", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!([%{"name" => "Movie.2024.1080p.mkv", "size" => 1}])
      )
    end)

    {:ok, bypass: bypass}
  end

  test "adopts an orphan onto the client that actually holds its torrent", %{bypass: bypass} do
    setup_runtime_config([reachable_client("qbit-new", bypass.port)])
    media_item = media_item_fixture()

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    # An earlier poll already parked this row: the client it referenced is
    # gone. `import_failed_at` and `import_next_retry_at` are seeded non-nil
    # (as `no_client`'s own terminal-after-3-attempts path in MediaImport
    # would leave them) so the nil assertions below are actually proving
    # `maybe_clear_orphan_state/2` clears those fields, not just resting on
    # a fixture default that was already nil.
    download =
      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "qbit-old",
        download_client_id: @hash,
        error_message: "Download client 'qbit-old' is no longer configured in Mydia.",
        import_failure_reason: "no_client",
        import_last_error: "Download client 'qbit-old' is no longer configured in Mydia.",
        import_failed_at: now,
        import_next_retry_at: now
      })

    # Before adoption the row is parked: error_message alone already excludes
    # it from occupying/1.
    refute download.id in occupying_ids()

    assert :ok = perform_job(DownloadMonitor, %{})

    updated = Downloads.get_download!(download.id)

    assert updated.download_client == "qbit-new"
    assert updated.error_message == nil
    assert updated.import_failure_reason == nil
    assert updated.import_last_error == nil
    assert updated.import_failed_at == nil
    assert updated.import_next_retry_at == nil

    # The whole point of clearing `import_failed_at` / `import_next_retry_at`
    # (not just `error_message`) is that the row returns to occupying its
    # target, exactly the set `MediaImport`'s own `no_client` terminal path
    # writes to when it gives up after 3 attempts.
    assert download.id in occupying_ids()
  end

  test "heals a legacy row written before the no_client tag existed", %{bypass: bypass} do
    # A row marked missing by the previously released code has the old
    # "Removed from download client" copy but no import_failure_reason at
    # all (the tag didn't exist yet). Without the widened gate in
    # maybe_clear_orphan_state/2, adoption would re-point such a row at its
    # new client but never clear the now-false message, so it would display
    # a permanent failure forever while downloading fine.
    setup_runtime_config([reachable_client("qbit-new", bypass.port)])
    media_item = media_item_fixture()

    download =
      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "qbit-old",
        download_client_id: @hash,
        error_message:
          "Removed from download client 'qbit-old' before import completed. " <>
            "The download may have been manually deleted, or the client may have encountered an error.",
        import_failure_reason: nil
      })

    assert :ok = perform_job(DownloadMonitor, %{})

    updated = Downloads.get_download!(download.id)

    assert updated.download_client == "qbit-new"
    assert updated.error_message == nil
    assert updated.import_failure_reason == nil
    assert download.id in occupying_ids()
  end

  test "re-enabling a disabled client clears the orphan state it produced", %{bypass: bypass} do
    # Two monitor passes with the client's `enabled` flag flipped between them:
    # exactly the sequence the disabled-client error message tells the operator
    # to perform. Orphaning must not be a one-way transition, otherwise the row
    # keeps a false error message and the Issues tab keeps offering to delete a
    # download that is visibly running on the Queue tab.
    setup_runtime_config([disabled_client("qbit", bypass.port)])
    media_item = media_item_fixture()

    download =
      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "qbit",
        download_client_id: @hash
      })

    assert :ok = perform_job(DownloadMonitor, %{})

    parked = Downloads.get_download!(download.id)
    assert parked.import_failure_reason == "no_client"
    assert parked.error_message =~ "is disabled in Mydia"
    refute download.id in occupying_ids()

    # The operator does what the message says.
    setup_runtime_config([reachable_client("qbit", bypass.port)])

    assert :ok = perform_job(DownloadMonitor, %{})

    healed = Downloads.get_download!(download.id)

    assert healed.download_client == "qbit"
    assert healed.error_message == nil
    assert healed.import_failure_reason == nil
    assert download.id in occupying_ids()

    # And the Issues-tab banner stops claiming this client is untracked.
    assert Downloads.removed_client_groups() == []
  end

  test "leaves an unrelated import failure intact when adopting" do
    # Adoption fixes which client owns the torrent. It does not vindicate a
    # broken import, so failure state this feature did not write must survive.
    bypass = Bypass.open()

    Bypass.stub(bypass, "POST", "/api/v2/auth/login", fn conn ->
      conn
      |> Plug.Conn.put_resp_header("set-cookie", "SID=test-sid; HttpOnly")
      |> Plug.Conn.resp(200, "Ok.")
    end)

    Bypass.stub(bypass, "GET", "/api/v2/torrents/info", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!([torrent_payload(@hash)]))
    end)

    Bypass.stub(bypass, "GET", "/api/v2/torrents/files", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!([%{"name" => "Movie.2024.1080p.mkv", "size" => 1}])
      )
    end)

    setup_runtime_config([reachable_client("qbit-new", bypass.port)])
    media_item = media_item_fixture()

    download =
      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "qbit-old",
        download_client_id: @hash,
        import_failure_reason: "path_mapping_mismatch",
        import_last_error: "Could not see /remote/path"
      })

    assert :ok = perform_job(DownloadMonitor, %{})

    updated = Downloads.get_download!(download.id)

    assert updated.download_client == "qbit-new"
    assert updated.import_failure_reason == "path_mapping_mismatch"
    assert updated.import_last_error == "Could not see /remote/path"
  end

  defp occupying_ids do
    Mydia.Downloads.Download
    |> Mydia.Downloads.Download.occupying()
    |> Mydia.Repo.all()
    |> Enum.map(& &1.id)
  end

  defp reachable_client(name, port) do
    %{
      name: name,
      type: :qbittorrent,
      enabled: true,
      host: "localhost",
      port: port,
      use_ssl: false,
      username: "admin",
      password: "adminpass",
      priority: 1
    }
  end

  # Same client, switched off: still in the config list, never polled.
  defp disabled_client(name, port) do
    %{reachable_client(name, port) | enabled: false}
  end

  defp torrent_payload(hash) do
    %{
      "hash" => hash,
      "name" => "Test Torrent",
      "state" => "downloading",
      "progress" => 0.5,
      "dlspeed" => 100_000,
      "upspeed" => 0,
      "downloaded" => 500,
      "uploaded" => 0,
      "size" => 1000,
      "eta" => 60,
      "ratio" => 0.0,
      "save_path" => "/downloads",
      "added_on" => 1_700_000_000,
      "completion_on" => -1
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
