defmodule Mydia.Downloads.HistoryRemoteFetchTest do
  @moduledoc """
  Proves `History.fetch_all_client_statuses/2` actually calls
  `Seedbox.maybe_apply_remote_fetch/3` when a client config has `remote_fetch`
  enabled — a regression guard for the wiring point itself, not a re-test of
  `Seedbox`'s own decision logic (covered by `Mydia.Downloads.SeedboxTest`).

  Uses a Bypass-stubbed qBittorrent client so `Client.list_torrents/2`
  actually reaches the `{:ok, torrents}` branch inside
  `fetch_all_client_statuses/2` — an unreachable client short-circuits to
  `{:error, _}` before that branch ever runs, which would make the wiring
  point untestable (an *unreachable* stand-in client proves nothing about
  whether `Seedbox` is still being called).
  """
  use Mydia.DataCase, async: false

  alias Mydia.Downloads
  alias Mydia.Downloads.Seedbox.Fetcher
  alias Mydia.Settings

  import Mydia.DownloadsFixtures

  @hash "torrent-1"

  setup do
    ensure_started!({Registry, keys: :unique, name: Mydia.Downloads.Seedbox.FetcherRegistry})

    ensure_started!(
      {DynamicSupervisor, name: Mydia.Downloads.Seedbox.FetcherSupervisor, strategy: :one_for_one}
    )

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

  defp ensure_started!(spec) do
    case start_supervised(spec) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "a remote-fetch-enabled client's finished torrent stays :queued instead of surfacing the client's own :seeding",
       %{bypass: bypass} do
    {:ok, client} =
      Settings.create_download_client_config(%{
        name: "seedbox-qbit-history",
        type: :qbittorrent,
        host: "127.0.0.1",
        port: bypass.port,
        username: "u",
        password: "adminpass",
        download_directory: "/tmp/downloads",
        connection_settings: %{
          "remote_fetch" => %{
            "enabled" => true,
            "host" => "127.0.0.1",
            "port" => 65_535,
            "username" => "u",
            "auth_method" => "password",
            "password" => "p"
          }
        }
      })

    download =
      download_fixture(%{
        title: "Release",
        download_client: client.name,
        download_client_id: @hash,
        metadata: %{}
      })

    downloads = Downloads.list_downloads_with_status(filter: :all)
    result = Enum.find(downloads, &(&1.id == download.id))

    # The stub reports "uploading" (qBittorrent's seeding state) — Seedbox
    # intercepts that and holds the download at "queued" until the local
    # SFTP pull completes, claiming a Fetcher in the process. If
    # `history.ex` stopped calling `Seedbox.maybe_apply_remote_fetch/3`,
    # this would read "seeding" (the client's own raw state) instead.
    assert result.status == "queued"
    assert {:ok, _pid} = Fetcher.whereis(download.id)
  end

  defp torrent_payload(hash) do
    %{
      "hash" => hash,
      "name" => "Test Torrent",
      "state" => "uploading",
      "progress" => 1.0,
      "dlspeed" => 0,
      "upspeed" => 0,
      "downloaded" => 1000,
      "uploaded" => 500,
      "size" => 1000,
      "eta" => 0,
      "ratio" => 0.5,
      "save_path" => "/remote/downloads/Release",
      "added_on" => 1_700_000_000,
      "completion_on" => 1_700_001_000
    }
  end
end
