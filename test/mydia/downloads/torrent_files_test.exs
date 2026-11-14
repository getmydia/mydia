defmodule Mydia.Downloads.TorrentFilesTest do
  use Mydia.DataCase, async: false

  import Mydia.DownloadsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.Structs.{EnrichedDownload, TorrentFile}
  alias Mydia.Downloads.TorrentFiles

  defmodule StubAdapter do
    @behaviour Mydia.Downloads.Client

    def put_files(result), do: :persistent_term.put({__MODULE__, :files}, result)
    def selections, do: :persistent_term.get({__MODULE__, :selections}, [])
    def cleanup, do: Enum.each([:files, :selections], &:persistent_term.erase({__MODULE__, &1}))

    @impl true
    def torrent_files(_config, _id), do: :persistent_term.get({__MODULE__, :files}, {:ok, []})

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

  setup do
    previous = Registry.lookup(:rqbit)
    Registry.register(:rqbit, StubAdapter)

    BuiltIn.put_runtime(%BuiltIn.Runtime{
      api_port: 3030,
      credentials: {"mydia", "s3cret"},
      config: struct!(BuiltIn.Config, [])
    })

    on_exit(fn ->
      BuiltIn.clear_runtime()
      StubAdapter.cleanup()
      if previous, do: Registry.register(:rqbit, previous), else: Registry.unregister(:rqbit)
    end)

    :ok
  end

  defp row(attrs \\ %{}) do
    download = download_fixture(%{download_client: BuiltIn.name()})

    struct!(
      EnrichedDownload,
      Map.merge(
        %{
          id: download.id,
          title: download.title,
          download_client: download.download_client,
          download_client_id: download.download_client_id,
          status: "downloading",
          metadata: %{},
          imported_at: nil
        },
        attrs
      )
    )
  end

  defp file(index, path), do: %TorrentFile{index: index, path: path, size: 1_000_000}

  test "supported? and editable?" do
    assert TorrentFiles.supported?(row())
    refute TorrentFiles.supported?(row(%{download_client_id: nil}))
    refute TorrentFiles.supported?(row(%{download_client: "nope"}))
    assert TorrentFiles.editable?(row())
    refute TorrentFiles.editable?(row(%{imported_at: DateTime.utc_now()}))
  end

  test "list returns the client's files" do
    StubAdapter.put_files({:ok, [file(0, "a/x.mkv")]})
    assert {:ok, [%TorrentFile{index: 0}]} = TorrentFiles.list(row())
  end

  test "save stamps manual and calls the adapter with the indices" do
    StubAdapter.put_files({:ok, [file(0, "a/x.mkv"), file(1, "a/x.srt")]})
    row = row()

    assert :ok = TorrentFiles.save(row, [0, 1])
    assert StubAdapter.selections() == [{row.download_client_id, [0, 1]}]
    assert %{"source" => "manual"} = Downloads.get_download!(row.id).metadata["file_selection"]
  end

  test "save refuses a selection with no importable file" do
    StubAdapter.put_files({:ok, [file(0, "a/x.mkv"), file(1, "a/x.srt")]})

    assert {:error, :no_importable_file} = TorrentFiles.save(row(), [1])
    assert {:error, :no_importable_file} = TorrentFiles.save(row(), [])
    assert StubAdapter.selections() == []
  end

  defp mark_imported(row) do
    row.id
    |> Downloads.get_download!()
    |> Ecto.Changeset.change(imported_at: DateTime.truncate(DateTime.utc_now(), :second))
    |> Mydia.Repo.update!()
  end

  test "save refuses after import" do
    StubAdapter.put_files({:ok, [file(0, "a/x.mkv")]})
    row = row(%{imported_at: DateTime.utc_now()})
    mark_imported(row)

    assert {:error, :imported} = TorrentFiles.save(row, [0])
    assert StubAdapter.selections() == []
  end

  test "save reads the import from the database, not the drawer's snapshot" do
    StubAdapter.put_files({:ok, [file(0, "a/x.mkv")]})
    # The drawer loaded the row before the import finished.
    row = row()
    mark_imported(row)

    assert {:error, :imported} = TorrentFiles.save(row, [0])
    assert StubAdapter.selections() == []
    refute Downloads.get_download!(row.id).metadata["file_selection"]
  end
end
