defmodule Mydia.Downloads.RemoveExternalTorrentTest do
  # Not async: swaps an adapter in the global client registry and writes the
  # shared ExternalTorrents cache.
  use Mydia.DataCase, async: false

  alias Mydia.Downloads
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.ExternalTorrents
  alias Mydia.Downloads.Structs.{ExternalScan, ExternalTorrent}

  import Mydia.SettingsFixtures

  defmodule RemoveAdapter do
    @behaviour Mydia.Downloads.Client

    @impl true
    def remove_torrent(_config, client_id, opts) do
      send(self(), {:removed, client_id, opts})
      :persistent_term.get({__MODULE__, :result}, :ok)
    end

    @impl true
    def list_torrents(_config, _opts), do: {:ok, []}
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
  end

  setup do
    original = Registry.lookup(:qbittorrent)
    Registry.register(:qbittorrent, RemoveAdapter)
    previous_scan = ExternalTorrents.get()

    on_exit(fn ->
      :persistent_term.erase({RemoveAdapter, :result})
      ExternalTorrents.put(previous_scan)
      if original, do: Registry.register(:qbittorrent, original)
    end)

    client = download_client_config_fixture(%{type: "qbittorrent"})
    torrent = torrent(client.name)
    ExternalTorrents.put(%ExternalScan{needs_matching: [torrent]})

    %{torrent: torrent}
  end

  defp torrent(client_name) do
    %ExternalTorrent{
      id: "#{client_name}:hash-orphan",
      client_name: client_name,
      client_id: "hash-orphan",
      title: "Quiet.Harbor.2024.1080p.WEB-DL.x264-GROUP",
      kind: :needs_matching
    }
  end

  test "removes the torrent with its files and drops it from the scan", %{torrent: torrent} do
    assert :ok = Downloads.remove_external_torrent(torrent, delete_files: true)

    assert_received {:removed, "hash-orphan", [delete_files: true]}
    assert ExternalTorrents.find(torrent.id) == nil
  end

  test "can keep the files", %{torrent: torrent} do
    assert :ok = Downloads.remove_external_torrent(torrent, delete_files: false)

    assert_received {:removed, "hash-orphan", [delete_files: false]}
  end

  test "a client error leaves the torrent listed", %{torrent: torrent} do
    :persistent_term.put({RemoveAdapter, :result}, {:error, :timeout})

    assert {:error, :timeout} = Downloads.remove_external_torrent(torrent, delete_files: true)
    assert ExternalTorrents.find(torrent.id) == torrent
  end

  test "a client that is no longer configured is an error", %{torrent: torrent} do
    gone = %{torrent | client_name: "no-such-client"}

    assert {:error, :no_client} = Downloads.remove_external_torrent(gone, delete_files: true)
    refute_received {:removed, _, _}
  end
end
