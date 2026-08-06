defmodule Mydia.Downloads.HistoryClientStateTest do
  @moduledoc """
  Covers the classification that `DownloadMonitor` acts on: a client that is
  present, one that is merely disabled, and one that is gone.

  No client in the first describe block is reachable over the network, so every
  configured client resolves to `:unreachable`. That is deliberate: it isolates
  the config-state classification from live torrent data. The second block
  stands up a real (stubbed) client, because a candidate can only be reported
  when a reachable claimant genuinely exists.
  """
  use Mydia.DataCase, async: false

  alias Mydia.Downloads

  import Mydia.MediaFixtures
  import Mydia.DownloadsFixtures

  @hash "1234567890abcdef1234567890abcdef12345678"

  describe "list_downloads_with_status/1 client config state" do
    test "marks a download whose client was removed" do
      setup_runtime_config([client_config(%{name: "kept", enabled: true})])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "gone",
        download_client_id: "hash-a"
      })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.client_config_state == :removed
      assert enriched.adoptable_client == nil
    end

    test "marks a download whose client is disabled, not removed" do
      setup_runtime_config([client_config(%{name: "paused", enabled: false})])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "paused",
        download_client_id: "hash-b"
      })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.client_config_state == :disabled
    end

    test "leaves client_config_state nil for a download with no client assigned" do
      setup_runtime_config([client_config(%{name: "kept", enabled: true})])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: nil,
        download_client_id: nil
      })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.client_config_state == nil
    end

    test "reports :present for a configured, enabled client" do
      setup_runtime_config([client_config(%{name: "kept", enabled: true})])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "kept",
        download_client_id: "hash-c"
      })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.client_config_state == :present
    end

    test "marks a download as :removed when no clients are configured at all" do
      # The single-client operator's shape: deleting your only client leaves
      # `all_configured == []`, an early-return branch that used to leave
      # `client_config_state` nil unconditionally. A download that still
      # names a client must classify :removed here too, not just when a
      # mismatched client is present in a non-empty list.
      setup_runtime_config([])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "gone",
        download_client_id: "hash-e"
      })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.client_config_state == :removed
    end

    test "leaves client_config_state nil with no clients configured and no client assigned" do
      setup_runtime_config([])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: nil,
        download_client_id: nil
      })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.client_config_state == nil
    end
  end

  describe "list_downloads_with_status/1 adoption candidates" do
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

    test "reports the candidate and the claimant's live status, and writes neither", %{
      bypass: bypass
    } do
      # A reachable claimant has to genuinely exist for this to prove anything:
      # with only unreachable clients configured, `find_claimant/3` returns
      # `:none` and the assertion below would hold even if the read path
      # persisted every adoption it found.
      setup_runtime_config([reachable_client("qbit-new", bypass.port)])
      media_item = media_item_fixture()

      download =
        download_fixture(%{
          media_item_id: media_item.id,
          download_client: "qbit-old",
          download_client_id: @hash
        })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      assert enriched.adoptable_client == "qbit-new"
      # Enriched from the claimant's torrent, so the UI shows real progress.
      assert enriched.status == "downloading"

      # The read path reports; it never persists. DownloadMonitor is the only
      # writer.
      persisted = Downloads.get_download!(download.id)
      assert persisted.download_client == "qbit-old"
    end
  end

  # Simulates a status-fetch task dying via `exit` (a GenServer.call or pool
  # checkout timeout) rather than raising — `try/rescue` in
  # `fetch_all_client_statuses/2` cannot catch an exit, so this is the only
  # way to reach that code path from a test.
  defmodule CrashingAdapter do
    @behaviour Mydia.Downloads.Client

    @impl true
    def supported_protocols, do: [:torrent]
    @impl true
    def test_connection(_config), do: {:ok, %{version: "1.0.0", api_version: "1.0"}}
    @impl true
    def add_torrent(_config, _torrent, _opts), do: {:ok, "crash-id"}
    @impl true
    def get_status(_config, _client_id), do: {:ok, %{}}
    @impl true
    def list_torrents(_config, _opts), do: exit(:simulated_crash)
    @impl true
    def pause_torrent(_config, _client_id), do: :ok
    @impl true
    def resume_torrent(_config, _client_id), do: :ok
    @impl true
    def remove_torrent(_config, _client_id, _opts), do: :ok
  end

  describe "list_downloads_with_status/1 client status fetch crashes" do
    test "degrades a crashed status-fetch task to :unreachable instead of vanishing" do
      alias Mydia.Downloads.Client.Registry

      original =
        case Registry.get_adapter(:qbittorrent) do
          {:ok, adapter} -> adapter
          {:error, _} -> nil
        end

      Registry.register(:qbittorrent, CrashingAdapter)
      on_exit(fn -> if original, do: Registry.register(:qbittorrent, original) end)

      setup_runtime_config([client_config(%{name: "flaky", enabled: true})])
      media_item = media_item_fixture()

      download_fixture(%{
        media_item_id: media_item.id,
        download_client: "flaky",
        download_client_id: "hash-crash"
      })

      [enriched] = Downloads.list_downloads_with_status(filter: :all)

      # Must read the same as a client that answered "down" cleanly, not as
      # a disabled/removed one — a crash mid-poll must not flip this
      # download to "missing" (see DownloadMonitor's missing-handler).
      assert enriched.client_config_state == :present
      assert enriched.status == "unknown"
    end
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

  defp reachable_client(name, port) do
    client_config(%{name: name, port: port, password: "adminpass"})
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
