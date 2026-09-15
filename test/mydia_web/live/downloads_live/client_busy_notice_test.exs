defmodule MydiaWeb.DownloadsLive.ClientBusyNoticeTest do
  # Not async: swaps an adapter in the global client registry and shortens the
  # status deadline through application env.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.ClientStatusCache
  alias Mydia.Downloads.Structs.DownloadStatus

  @hash "89abcdef0123456789abcdef0123456789abcdef"

  defmodule SlowAdapter do
    @behaviour Mydia.Downloads.Client

    @impl true
    def list_torrents(_config, _opts) do
      Process.sleep(500)
      # An {:ok, []} would be stored as the latest snapshot and wipe the last
      # known status the page is supposed to show. A late error does not.
      {:error, :slow}
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

  setup %{conn: conn} do
    original =
      case Registry.get_adapter(:qbittorrent) do
        {:ok, adapter} -> adapter
        {:error, _} -> nil
      end

    Registry.register(:qbittorrent, SlowAdapter)

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

    # LiveView's connected mount runs in another process. Creating the client
    # here matches the other Downloads LiveView tests so that process sees it.
    client = download_client_config_fixture(%{type: "qbittorrent"})

    %{conn: log_in_user(conn, admin_user_fixture()), client: client}
  end

  test "names the busy client when rows show its last known status", %{conn: conn, client: client} do
    media_item = media_item_fixture(%{title: "Fictional Salt Meridian"})

    download_fixture(%{
      media_item_id: media_item.id,
      download_client: client.name,
      download_client_id: @hash
    })

    ClientStatusCache.put(
      client.name,
      %{
        @hash => %DownloadStatus{
          id: @hash,
          name: "Fictional Salt Meridian",
          state: :downloading,
          progress: 40.0
        }
      },
      DateTime.add(DateTime.utc_now(), -30, :second)
    )

    {:ok, view, _html} = live(conn, ~p"/downloads")

    assert has_element?(view, "#client-busy-notice", client.name)
  end

  test "stays hidden when no client is busy", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/downloads")

    refute has_element?(view, "#client-busy-notice")
  end
end
