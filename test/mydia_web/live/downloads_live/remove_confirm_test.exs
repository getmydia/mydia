defmodule MydiaWeb.DownloadsLive.RemoveConfirmTest do
  # Not async: swaps an adapter in the global client registry and writes the
  # shared ExternalTorrents cache.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.ExternalTorrents
  alias Mydia.Downloads.Structs.{DownloadStatus, ExternalScan, ExternalTorrent}

  @hash "6666666666666666666666666666666666666666"

  defmodule Adapter do
    @behaviour Mydia.Downloads.Client

    def put(statuses), do: :persistent_term.put({__MODULE__, :statuses}, statuses)

    @impl true
    def list_torrents(_config, _opts),
      do: {:ok, :persistent_term.get({__MODULE__, :statuses}, [])}

    @impl true
    def remove_torrent(_config, client_id, opts) do
      :persistent_term.put({__MODULE__, :removed}, {client_id, opts})
      :ok
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
  end

  setup %{conn: conn} do
    original = Registry.lookup(:qbittorrent)
    Registry.register(:qbittorrent, Adapter)
    :ok = ExternalTorrents.put(ExternalScan.empty())

    on_exit(fn ->
      :persistent_term.erase({Adapter, :statuses})
      :persistent_term.erase({Adapter, :removed})
      ExternalTorrents.put(ExternalScan.empty())
      if original, do: Registry.register(:qbittorrent, original)
    end)

    client = download_client_config_fixture(%{type: "qbittorrent"})
    %{conn: log_in_user(conn, admin_user_fixture()), client: client}
  end

  defp imported_download!(client) do
    item = media_item_fixture(%{title: "Fictional Paper Orchard"})

    Adapter.put([
      %DownloadStatus{
        id: @hash,
        name: "Fictional Paper Orchard",
        state: :seeding,
        progress: 100.0
      }
    ])

    download_fixture(%{
      media_item_id: item.id,
      download_client: client.name,
      download_client_id: @hash,
      imported_at: DateTime.utc_now() |> DateTime.truncate(:second)
    })
  end

  describe "a finished download's trash button" do
    test "asks first, deleting the files by default", %{conn: conn, client: client} do
      download = imported_download!(client)
      {:ok, view, _html} = live(conn, ~p"/downloads?view=all")

      view |> element("#row-clear-#{download.id}") |> render_click()

      assert has_element?(view, "#remove-confirm-modal[open]")
      assert has_element?(view, "#remove-confirm-delete-files[checked]")
      refute Mydia.Downloads.get_download!(download.id).removal_requested_at

      view |> element("#remove-confirm-form") |> render_submit(%{"delete_files" => "true"})

      refute has_element?(view, "#remove-confirm-modal")
      removing = Mydia.Downloads.get_download!(download.id)
      assert removing.removal_requested_at
      assert removing.removal_kind == "clear"
      assert removing.removal_delete_files
    end

    test "can keep the files", %{conn: conn, client: client} do
      download = imported_download!(client)
      {:ok, view, _html} = live(conn, ~p"/downloads?view=all")

      view |> element("#row-clear-#{download.id}") |> render_click()
      view |> element("#remove-confirm-form") |> render_change(%{"delete_files" => "false"})

      refute has_element?(view, "#remove-confirm-delete-files[checked]")
      assert has_element?(view, "#remove-confirm-submit", "Remove")

      view |> element("#remove-confirm-form") |> render_submit(%{"delete_files" => "false"})

      refute Mydia.Downloads.get_download!(download.id).removal_delete_files
    end

    test "Cancel removes nothing", %{conn: conn, client: client} do
      download = imported_download!(client)
      {:ok, view, _html} = live(conn, ~p"/downloads?view=all")

      view |> element("#row-clear-#{download.id}") |> render_click()
      view |> element("#remove-confirm-cancel") |> render_click()

      refute has_element?(view, "#remove-confirm-modal")
      refute Mydia.Downloads.get_download!(download.id).removal_requested_at
    end
  end

  # Issue #1436: Cancel used a browser confirm and always kept the partial
  # files, which blocked a later grab of the same release.
  describe "an in-flight download's cancel button" do
    defp in_flight_download!(client) do
      item = media_item_fixture(%{title: "Fictional Tin Meadow"})

      Adapter.put([
        %DownloadStatus{
          id: @hash,
          name: "Fictional Tin Meadow",
          state: :downloading,
          progress: 40.0
        }
      ])

      download_fixture(%{
        media_item_id: item.id,
        title: "Fictional Tin Meadow",
        download_client: client.name,
        download_client_id: @hash
      })
    end

    test "asks first, deleting the partial files by default", %{conn: conn, client: client} do
      download = in_flight_download!(client)
      {:ok, view, _html} = live(conn, ~p"/downloads")

      refute has_element?(view, "#row-cancel-#{download.id}[data-confirm]")
      view |> element("#row-cancel-#{download.id}") |> render_click()

      assert has_element?(view, "#remove-confirm-modal[open]", "Fictional Tin Meadow")
      assert has_element?(view, "#remove-confirm-modal", "Cancel download")
      assert has_element?(view, "#remove-confirm-delete-files[checked]")
      assert has_element?(view, "#remove-confirm-cancel", "Keep downloading")
      refute Mydia.Downloads.get_download!(download.id).removal_requested_at

      view |> element("#remove-confirm-form") |> render_submit(%{"delete_files" => "true"})

      refute has_element?(view, "#remove-confirm-modal")
      removing = Mydia.Downloads.get_download!(download.id)
      assert removing.removal_requested_at
      assert removing.removal_kind == "cancel"
      assert removing.removal_delete_files
    end

    test "can keep the partial files", %{conn: conn, client: client} do
      download = in_flight_download!(client)
      {:ok, view, _html} = live(conn, ~p"/downloads")

      view |> element("#row-cancel-#{download.id}") |> render_click()
      view |> element("#remove-confirm-form") |> render_change(%{"delete_files" => "false"})

      assert has_element?(view, "#remove-confirm-submit", "Cancel download")

      view |> element("#remove-confirm-form") |> render_submit(%{"delete_files" => "false"})

      removing = Mydia.Downloads.get_download!(download.id)
      assert removing.removal_kind == "cancel"
      refute removing.removal_delete_files
    end
  end

  describe "a client torrent awaiting a match in Issues" do
    setup %{client: client} do
      torrent = %ExternalTorrent{
        id: "orphan",
        client_name: client.name,
        client_id: "hash-orphan",
        title: "Fictional.Paper.Orchard.2024.1080p.WEB-DL",
        kind: :needs_matching,
        status: :seeding,
        progress: 100.0,
        suggestions: []
      }

      :ok = ExternalTorrents.put(%{ExternalScan.empty() | needs_matching: [torrent]})
      :ok
    end

    test "can be removed from the client with its files", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues")

      view |> element("#issue-remove-torrent-orphan") |> render_click()
      assert has_element?(view, "#remove-confirm-modal[open]", "Fictional.Paper.Orchard")

      view |> element("#remove-confirm-form") |> render_submit(%{"delete_files" => "true"})

      assert :persistent_term.get({Adapter, :removed}) == {"hash-orphan", [delete_files: true]}
      refute has_element?(view, "#issues-orphan")
      assert ExternalTorrents.find("orphan") == nil
    end

    test "a torrent gone before the click says so", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues")
      :ok = ExternalTorrents.put(ExternalScan.empty())

      view |> element("#issue-remove-torrent-orphan") |> render_click()

      refute has_element?(view, "#remove-confirm-modal")
      assert render(view) =~ "That torrent is no longer in the client"
    end
  end
end
