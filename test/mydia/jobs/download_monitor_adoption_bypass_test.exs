defmodule Mydia.Jobs.DownloadMonitorAdoptionBypassTest do
  @moduledoc """
  The adoption success path, end to end.

  A download references 'qbit-old', which no longer exists. A configured,
  reachable client named 'qbit-new' holds the same info hash. One monitor pass
  must re-point the download at 'qbit-new' and clear the orphan error state
  written by an earlier pass, so a row parked in the Issues tab comes back to
  life when the operator re-adds their client.
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

    {:ok, bypass: bypass}
  end

  test "adopts an orphan onto the client that actually holds its torrent", %{bypass: bypass} do
    setup_runtime_config([reachable_client("qbit-new", bypass.port)])
    media_item = media_item_fixture()

    # An earlier poll already parked this row: the client it referenced is gone.
    download =
      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "qbit-old",
        download_client_id: @hash,
        error_message: "Download client 'qbit-old' is no longer configured in Mydia.",
        import_failure_reason: "no_client"
      })

    assert :ok = perform_job(DownloadMonitor, %{})

    updated = Downloads.get_download!(download.id)

    assert updated.download_client == "qbit-new"
    assert updated.error_message == nil
    assert updated.import_failure_reason == nil
    assert updated.import_failed_at == nil
    assert updated.import_next_retry_at == nil
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
