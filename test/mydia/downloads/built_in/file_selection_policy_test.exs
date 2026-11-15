defmodule Mydia.Downloads.BuiltIn.FileSelectionPolicyTest do
  use Mydia.DataCase, async: false

  import Mydia.DownloadsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{FileSelectionPolicy, Policies}
  alias Mydia.Downloads.TorrentFiles
  alias Mydia.Downloads.Client.{Error, Registry}
  alias Mydia.Downloads.Structs.{EnrichedDownload, TorrentFile}

  defmodule StubAdapter do
    @behaviour Mydia.Downloads.Client

    @keys [:files, :selections, :list_calls, :fail, :notify]

    def reset do
      :persistent_term.put({__MODULE__, :files}, {:ok, []})
      :persistent_term.put({__MODULE__, :selections}, [])
      :persistent_term.put({__MODULE__, :list_calls}, 0)
      :persistent_term.put({__MODULE__, :fail}, false)
    end

    def put_files(result), do: :persistent_term.put({__MODULE__, :files}, result)
    # `pid` is sent `:files_listed` each time the file list is read.
    def notify(pid), do: :persistent_term.put({__MODULE__, :notify}, pid)
    def fail!, do: :persistent_term.put({__MODULE__, :fail}, true)
    def selections, do: :persistent_term.get({__MODULE__, :selections}, [])
    def list_calls, do: :persistent_term.get({__MODULE__, :list_calls}, 0)
    def cleanup, do: Enum.each(@keys, &:persistent_term.erase({__MODULE__, &1}))

    @impl true
    def torrent_files(_config, _id) do
      :persistent_term.put({__MODULE__, :list_calls}, list_calls() + 1)

      case :persistent_term.get({__MODULE__, :notify}, nil) do
        pid when is_pid(pid) -> send(pid, :files_listed)
        nil -> :ok
      end

      if :persistent_term.get({__MODULE__, :fail}, false),
        do: {:error, Error.connection_failed("down")},
        else: :persistent_term.get({__MODULE__, :files}, {:ok, []})
    end

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
    StubAdapter.reset()

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
    download =
      download_fixture(%{
        download_client: BuiltIn.name(),
        metadata: Map.get(attrs, :metadata, %{})
      })

    fields =
      Map.merge(
        %{
          title: download.title,
          status: "downloading",
          metadata: download.metadata || %{},
          imported_at: nil,
          in_client?: true
        },
        Map.delete(attrs, :metadata)
      )

    struct!(
      EnrichedDownload,
      Map.merge(
        %{
          id: download.id,
          download_client: download.download_client,
          download_client_id: download.download_client_id
        },
        fields
      )
    )
  end

  defp reload(row), do: %{row | metadata: Downloads.get_download!(row.id).metadata || %{}}
  defp stamped(row), do: Downloads.get_download!(row.id).metadata["file_selection"]

  defp file(index, path, size \\ 1_500_000_000),
    do: %TorrentFile{index: index, path: path, size: size}

  defp video_and_junk do
    [
      file(0, "Fake.Show.S01E01.1080p/fake.show.s01e01.mkv"),
      file(1, "Fake.Show.S01E01.1080p/release.nfo", 2_000)
    ]
  end

  test "waits while the file list is empty (magnet without metadata)" do
    row = row()
    assert :waiting = FileSelectionPolicy.apply(row)
    assert StubAdapter.selections() == []
    refute stamped(row)
  end

  test "a manual save made after the poll snapshot is never overridden" do
    StubAdapter.put_files({:ok, video_and_junk()})
    # The poll read the row before the operator saved a selection.
    row = row()
    :ok = Mydia.Downloads.MetadataKey.put(row.id, "file_selection", %{"source" => "manual"})

    assert :done = FileSelectionPolicy.apply(row)
    assert StubAdapter.selections() == []
    assert stamped(row) == %{"source" => "manual"}
  end

  test "a policy run waiting on the selection lock sees the manual stamp saved under it" do
    StubAdapter.put_files({:ok, video_and_junk()})
    row = row()
    StubAdapter.notify(self())

    # The test holds the lock as the operator's save would. The policy reads
    # the file list (outside the lock), then blocks on the lock; the manual
    # stamp is written before the lock is released, so whenever the policy
    # gets it, its final check sees "manual".
    task =
      TorrentFiles.with_selection_lock(row.id, fn ->
        task = Task.async(fn -> FileSelectionPolicy.apply(row) end)
        assert_receive :files_listed, 5_000
        :ok = Mydia.Downloads.MetadataKey.put(row.id, "file_selection", %{"source" => "manual"})
        task
      end)

    assert Task.await(task, 30_000) == :done
    assert StubAdapter.selections() == []
    assert stamped(row) == %{"source" => "manual"}
  end

  test "an import finished after the poll snapshot is never overridden" do
    StubAdapter.put_files({:ok, video_and_junk()})
    # The poll read the row before the import finished.
    row = row()

    row.id
    |> Downloads.get_download!()
    |> Ecto.Changeset.change(imported_at: DateTime.truncate(DateTime.utc_now(), :second))
    |> Mydia.Repo.update!()

    assert :done = FileSelectionPolicy.apply(row)
    assert StubAdapter.selections() == []
    refute stamped(row)
  end

  test "a failure after a manual save keeps the manual stamp" do
    StubAdapter.fail!()
    row = row()
    :ok = Mydia.Downloads.MetadataKey.put(row.id, "file_selection", %{"source" => "manual"})

    assert {:error, _} = FileSelectionPolicy.apply(row)
    assert stamped(row) == %{"source" => "manual"}
  end

  test "waits while the torrent is checking, without asking the client" do
    assert :waiting = FileSelectionPolicy.apply(row(%{status: "checking"}))
    assert StubAdapter.list_calls() == 0
  end

  test "skips junk once and stamps auto with the count" do
    StubAdapter.put_files({:ok, video_and_junk()})
    row = row()

    assert :applied = FileSelectionPolicy.apply(row)
    assert StubAdapter.selections() == [{row.download_client_id, [0]}]
    assert %{"source" => "auto", "skipped" => 1} = stamped(row)

    assert :done = FileSelectionPolicy.apply(reload(row))
    assert length(StubAdapter.selections()) == 1
  end

  test "stamps nothing_to_skip without calling set_file_selection" do
    StubAdapter.put_files({:ok, [hd(video_and_junk())]})
    row = row()

    assert :nothing_to_skip = FileSelectionPolicy.apply(row)
    assert StubAdapter.selections() == []
    assert %{"source" => "auto", "skipped" => 0} = stamped(row)
  end

  test "never overrides a manual selection" do
    StubAdapter.put_files({:ok, video_and_junk()})
    row = row(%{metadata: %{"file_selection" => %{"source" => "manual"}}})

    assert :done = FileSelectionPolicy.apply(row)
    assert StubAdapter.list_calls() == 0
    assert StubAdapter.selections() == []
  end

  test "defers to a selection WantedFiles recorded at grab" do
    StubAdapter.put_files({:ok, video_and_junk()})
    entry = FileSelectionPolicy.auto_entry(4)
    row = row(%{metadata: %{"file_selection" => entry, "selected_files" => [0]}})

    assert :done = FileSelectionPolicy.apply(row)
    assert StubAdapter.list_calls() == 0
    assert StubAdapter.selections() == []
    assert stamped(row) == %{"source" => "auto", "skipped" => 4}
  end

  test "an imported row is done without a call" do
    row = row(%{imported_at: DateTime.utc_now()})
    assert :done = FileSelectionPolicy.apply(row)
    assert StubAdapter.list_calls() == 0
  end

  test "gives up after three failures" do
    StubAdapter.fail!()
    row = row()

    assert {:error, _} = FileSelectionPolicy.apply(row)
    assert %{"source" => "auto_pending", "attempts" => 1} = stamped(row)

    assert {:error, _} = row |> reload() |> FileSelectionPolicy.apply()
    assert %{"source" => "auto_pending", "attempts" => 2} = stamped(row)

    assert {:error, _} = row |> reload() |> FileSelectionPolicy.apply()
    assert %{"source" => "auto_failed", "attempts" => 3} = stamped(row)

    calls = StubAdapter.list_calls()
    assert :done = row |> reload() |> FileSelectionPolicy.apply()
    assert StubAdapter.list_calls() == calls
  end

  test "Policies.run applies selection to active in-client rows only" do
    StubAdapter.put_files({:ok, video_and_junk()})
    active = row()
    seeding = row(%{status: "seeding"})
    gone = row(%{in_client?: false})

    assert :ok = Policies.run([active, seeding, gone], DateTime.utc_now())

    assert StubAdapter.selections() == [{active.download_client_id, [0]}]
    assert stamped(active)
    refute stamped(seeding)
    refute stamped(gone)
  end
end
