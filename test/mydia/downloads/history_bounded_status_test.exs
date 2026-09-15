defmodule Mydia.Downloads.HistoryBoundedStatusTest do
  @moduledoc """
  A page asks for a bounded poll, so a client too busy to answer cannot hold the
  render. `DelayedAdapter` stands in for Transmission, which answers no RPC while
  it deletes a large torrent's data.
  """
  # Not async: swaps an adapter in the global client registry and shortens the
  # deadline through application env.
  use Mydia.DataCase, async: false

  import Mydia.DownloadsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.ClientStatusCache
  alias Mydia.Downloads.Structs.DownloadStatus

  @hash "0123456789abcdef0123456789abcdef01234567"

  defmodule DelayedAdapter do
    @behaviour Mydia.Downloads.Client

    alias Mydia.Downloads.Structs.DownloadStatus

    def set_delay(ms), do: :persistent_term.put({__MODULE__, :delay_ms}, ms)

    @impl true
    def list_torrents(_config, _opts) do
      Process.sleep(:persistent_term.get({__MODULE__, :delay_ms}, 0))

      {:ok,
       [
         %DownloadStatus{
           id: "0123456789abcdef0123456789abcdef01234567",
           name: "Fictional Release",
           state: :downloading,
           progress: 25.0
         }
       ]}
    end

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

  setup do
    original =
      case Registry.get_adapter(:qbittorrent) do
        {:ok, adapter} -> adapter
        {:error, _} -> nil
      end

    Registry.register(:qbittorrent, DelayedAdapter)
    DelayedAdapter.set_delay(500)

    previous_wait = Application.get_env(:mydia, :client_status_wait_ms)
    Application.put_env(:mydia, :client_status_wait_ms, 100)

    on_exit(fn ->
      case original do
        nil -> Registry.unregister(:qbittorrent)
        adapter -> Registry.register(:qbittorrent, adapter)
      end

      case previous_wait do
        nil -> Application.delete_env(:mydia, :client_status_wait_ms)
        value -> Application.put_env(:mydia, :client_status_wait_ms, value)
      end
    end)

    client = download_client_config_fixture(%{type: "qbittorrent"})
    download = download_fixture(%{download_client: client.name, download_client_id: @hash})

    %{client: client, download: download}
  end

  defp snapshot(torrents_map, client, seconds_ago \\ 30) do
    fetched_at =
      DateTime.utc_now() |> DateTime.add(-seconds_ago, :second) |> DateTime.truncate(:second)

    ClientStatusCache.put(client.name, torrents_map, fetched_at)
    fetched_at
  end

  defp row(rows, download), do: Enum.find(rows, &(&1.id == download.id))

  test "a client that misses the deadline shows its last snapshot, dated", %{
    client: client,
    download: download
  } do
    fetched_at =
      snapshot(
        %{
          @hash => %DownloadStatus{
            id: @hash,
            name: "Fictional Release",
            state: :downloading,
            progress: 60.0
          }
        },
        client
      )

    {elapsed_us, rows} =
      :timer.tc(fn -> Downloads.list_downloads_with_status(filter: :all, bounded: true) end)

    enriched = row(rows, download)
    assert enriched.status == "downloading"
    assert enriched.progress == 60.0
    assert enriched.status_as_of == fetched_at
    assert elapsed_us < 400_000
  end

  test "a torrent absent from the snapshot is unknown, never missing", %{
    client: client,
    download: download
  } do
    snapshot(%{}, client)

    enriched = row(Downloads.list_downloads_with_status(filter: :all, bounded: true), download)

    assert enriched.status == "unknown"
    assert is_nil(enriched.status_as_of)
  end

  test "with no snapshot a late client reads as unreachable", %{download: download} do
    enriched = row(Downloads.list_downloads_with_status(filter: :all, bounded: true), download)

    assert enriched.status == "unknown"
    assert is_nil(enriched.status_as_of)
  end

  test "a bounded read of a client that answers in time is live", %{
    client: client,
    download: download
  } do
    DelayedAdapter.set_delay(0)
    snapshot(%{}, client)

    enriched = row(Downloads.list_downloads_with_status(filter: :all, bounded: true), download)

    assert enriched.progress == 25.0
    assert is_nil(enriched.status_as_of)
  end

  test "an unbounded read waits for the answer and stores it", %{
    client: client,
    download: download
  } do
    enriched = row(Downloads.list_downloads_with_status(filter: :all), download)

    assert enriched.status == "downloading"
    assert enriched.progress == 25.0
    assert is_nil(enriched.status_as_of)

    assert {%{@hash => %DownloadStatus{progress: 25.0}}, %DateTime{}} =
             ClientStatusCache.get(client.name)
  end
end
