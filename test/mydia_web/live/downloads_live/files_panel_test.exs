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

    @keys [:files, :selections, :files_down, :selection_fails]

    def put_files(files), do: :persistent_term.put({__MODULE__, :files}, files)
    def selections, do: :persistent_term.get({__MODULE__, :selections}, [])
    # The client stops answering for its file list.
    def files_down!, do: :persistent_term.put({__MODULE__, :files_down}, true)
    # The selection is refused, and the client goes down with it.
    def selection_fails!, do: :persistent_term.put({__MODULE__, :selection_fails}, true)
    def cleanup, do: Enum.each(@keys, &:persistent_term.erase({__MODULE__, &1}))

    @impl true
    def torrent_files(_config, _id) do
      if :persistent_term.get({__MODULE__, :files_down}, false),
        do: {:error, Mydia.Downloads.Client.Error.connection_failed("down")},
        else: {:ok, :persistent_term.get({__MODULE__, :files}, [])}
    end

    @impl true
    def set_file_selection(_config, id, indexes) do
      if :persistent_term.get({__MODULE__, :selection_fails}, false) do
        files_down!()
        {:error, Mydia.Downloads.Client.Error.connection_failed("down")}
      else
        :persistent_term.put({__MODULE__, :selections}, [{id, indexes} | selections()])
        :ok
      end
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

  test "a failed save keeps its error visible when the file list cannot be reloaded",
       %{conn: conn} do
    view = open(conn, built_in_download())
    StubAdapter.selection_fails!()

    view |> form("#download-files-form", %{"files" => ["0"]}) |> render_submit()

    assert has_element?(view, "#download-files-error", "Couldn't update the file selection.")
  end

  test "saving an imported download shows why and turns the panel read-only", %{conn: conn} do
    view = open(conn, built_in_download(%{imported_at: DateTime.utc_now()}))
    StubAdapter.files_down!()

    # The checkboxes are disabled, so submit the event directly, as a stale
    # page would.
    view |> element("#download-files-form") |> render_submit(%{"files" => ["0"]})

    assert has_element?(view, "#download-files-error", "This download was already imported.")
    refute has_element?(view, "#download-files-save")
    assert StubAdapter.selections() == []
  end

  test "is read-only after import", %{conn: conn} do
    view = open(conn, built_in_download(%{imported_at: DateTime.utc_now()}))

    assert has_element?(view, "#download-files-form input[type=checkbox][disabled]")
    refute has_element?(view, "#download-files-save")
  end

  test "opened before the metadata resolves, it offers a refresh that lists the files later",
       %{conn: conn} do
    files = :persistent_term.get({StubAdapter, :files})
    StubAdapter.put_files([])
    view = open(conn, built_in_download())

    assert has_element?(view, "#download-files-panel #download-files-unavailable")
    assert has_element?(view, "#download-files-refresh")
    refute has_element?(view, "#download-files-form")

    # The metadata resolved; the operator asks again.
    StubAdapter.put_files(files)
    view |> element("#download-files-refresh") |> render_click()

    assert has_element?(view, "#download-files-form input[type=checkbox][value='0']")
    assert has_element?(view, "#download-files-form input[type=checkbox][value='1']")
    refute has_element?(view, "#download-files-refresh")
  end

  test "a failed file list load can be refreshed", %{conn: conn} do
    StubAdapter.files_down!()
    view = open(conn, built_in_download())

    assert has_element?(view, "#download-files-refresh")

    :persistent_term.erase({StubAdapter, :files_down})
    view |> element("#download-files-refresh") |> render_click()

    assert has_element?(view, "#download-files-form input[type=checkbox][value='0']")
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
