defmodule MydiaWeb.DownloadsLive.FilesPanelTest do
  # Not async: swaps an adapter in the global client registry and sets the
  # built-in runtime.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.DownloadsFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Structs.TorrentFile

  defmodule StubAdapter do
    @behaviour Mydia.Downloads.Client

    def put_files(files), do: :persistent_term.put({__MODULE__, :files}, files)
    def selections, do: :persistent_term.get({__MODULE__, :selections}, [])
    def cleanup, do: Enum.each([:files, :selections], &:persistent_term.erase({__MODULE__, &1}))

    @impl true
    def torrent_files(_config, _id),
      do: {:ok, :persistent_term.get({__MODULE__, :files}, [])}

    @impl true
    def set_file_selection(_config, id, indexes) do
      :persistent_term.put({__MODULE__, :selections}, [{id, indexes} | selections()])
      :ok
    end

    @impl true
    def pause_torrent(_, _), do: :ok
    @impl true
    def get_status(_, _), do: {:error, :not_implemented}
    @impl true
    def remove_torrent(_, _, _), do: :ok
    @impl true
    def test_connection(_), do: {:error, :not_implemented}
    @impl true
    def add_torrent(_, _, _), do: {:error, :not_implemented}
    @impl true
    def list_torrents(_, _), do: {:ok, []}
    @impl true
    def resume_torrent(_, _), do: :ok
    @impl true
    def supported_protocols, do: [:torrent]
  end

  defmodule PlainAdapter do
    @behaviour Mydia.Downloads.Client

    @impl true
    def list_torrents(_, _), do: {:ok, []}
    @impl true
    def supported_protocols, do: [:torrent]
    @impl true
    def test_connection(_), do: {:error, :not_implemented}
    @impl true
    def add_torrent(_, _, _), do: {:error, :not_implemented}
    @impl true
    def get_status(_, _), do: {:error, :not_implemented}
    @impl true
    def pause_torrent(_, _), do: :ok
    @impl true
    def resume_torrent(_, _), do: :ok
    @impl true
    def remove_torrent(_, _, _), do: :ok
  end

  setup %{conn: conn} do
    previous_rqbit = Registry.lookup(:rqbit)
    previous_qb = Registry.lookup(:qbittorrent)
    Registry.register(:rqbit, StubAdapter)
    Registry.register(:qbittorrent, PlainAdapter)

    BuiltIn.put_runtime(%BuiltIn.Runtime{
      api_port: 3030,
      credentials: {"mydia", "s3cret"},
      config: struct!(BuiltIn.Config, [])
    })

    StubAdapter.put_files([
      %TorrentFile{
        index: 0,
        path: "Fictional.Marsh.S01E01/marsh.s01e01.mkv",
        size: 1_500_000_000
      },
      %TorrentFile{index: 1, path: "Fictional.Marsh.S01E01/marsh.s01e01.srt", size: 40_000}
    ])

    on_exit(fn ->
      BuiltIn.clear_runtime()
      StubAdapter.cleanup()

      if previous_rqbit,
        do: Registry.register(:rqbit, previous_rqbit),
        else: Registry.unregister(:rqbit)

      if previous_qb,
        do: Registry.register(:qbittorrent, previous_qb),
        else: Registry.unregister(:qbittorrent)
    end)

    %{conn: log_in_user(conn, admin_user_fixture())}
  end

  defp open(conn, download) do
    {:ok, view, _html} = live(conn, ~p"/downloads?view=all&download=#{download.id}")
    view
  end

  defp built_in_download(attrs \\ %{}) do
    download_fixture(Map.merge(%{download_client: BuiltIn.name()}, attrs))
  end

  test "lists files with checkboxes", %{conn: conn} do
    view = open(conn, built_in_download())

    assert has_element?(view, "#download-files-form input[type=checkbox][value='0']")
    assert has_element?(view, "#download-files-form input[type=checkbox][value='1']")
    assert has_element?(view, "#download-files-save")
  end

  test "saving submits the selection", %{conn: conn} do
    download = built_in_download()
    view = open(conn, download)

    view |> form("#download-files-form", %{"files" => ["0"]}) |> render_submit()

    assert StubAdapter.selections() == [{download.download_client_id, [0]}]

    assert %{"source" => "manual"} =
             Downloads.get_download!(download.id).metadata["file_selection"]
  end

  test "shows the inline error when no video file is kept", %{conn: conn} do
    download = built_in_download()
    view = open(conn, download)

    view |> form("#download-files-form", %{"files" => ["1"]}) |> render_submit()

    assert has_element?(view, "#download-files-error", "Keep at least one video file.")
    assert StubAdapter.selections() == []
  end

  test "is read-only after import", %{conn: conn} do
    view = open(conn, built_in_download(%{imported_at: DateTime.utc_now()}))

    assert has_element?(view, "#download-files-form input[type=checkbox][disabled]")
    refute has_element?(view, "#download-files-save")
  end

  test "is absent for a client without file selection", %{conn: conn} do
    client = download_client_config_fixture(%{type: "qbittorrent"})
    download = download_fixture(%{download_client: client.name})
    view = open(conn, download)

    assert has_element?(view, "#download-detail")
    refute has_element?(view, "#download-files-form")
    refute has_element?(view, "#download-files-panel")
  end
end
