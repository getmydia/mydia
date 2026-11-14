defmodule Mydia.Downloads.BuiltIn.SeedingPolicyTest do
  use Mydia.DataCase, async: false

  import Mydia.DownloadsFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.{Policies, SeedingPolicy}
  alias Mydia.Downloads.Client.{Error, Registry}
  alias Mydia.Downloads.Structs.EnrichedDownload

  defmodule StubAdapter do
    @behaviour Mydia.Downloads.Client

    def reset, do: :persistent_term.put({__MODULE__, :pauses}, [])
    def pauses, do: :persistent_term.get({__MODULE__, :pauses}, [])
    def fail!, do: :persistent_term.put({__MODULE__, :fail}, true)
    def cleanup, do: Enum.each([:pauses, :fail], &:persistent_term.erase({__MODULE__, &1}))

    @impl true
    def pause_torrent(_config, id) do
      :persistent_term.put({__MODULE__, :pauses}, [id | pauses()])

      if :persistent_term.get({__MODULE__, :fail}, false),
        do: {:error, Error.connection_failed("down")},
        else: :ok
    end

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
    put_target(seed_ratio: 1.0)

    on_exit(fn ->
      BuiltIn.clear_runtime()
      StubAdapter.cleanup()
      if previous, do: Registry.register(:rqbit, previous), else: Registry.unregister(:rqbit)
    end)

    :ok
  end

  defp put_target(fields) do
    BuiltIn.put_runtime(%BuiltIn.Runtime{
      api_port: 3030,
      credentials: {"mydia", "s3cret"},
      config: struct!(BuiltIn.Config, fields)
    })
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
          status: "seeding",
          ratio: 1.2,
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

  defp stamp(row), do: Downloads.get_download!(row.id).metadata["seeding_goal_reached_at"]
  defp now, do: DateTime.utc_now()

  test "pauses a seeding row whose goal is met and stamps it" do
    row = row()
    assert :paused = SeedingPolicy.apply(row, now())
    assert StubAdapter.pauses() == [row.download_client_id]
    assert stamp(row)
  end

  test "does nothing below the goal" do
    row = row(%{ratio: 0.5})
    assert :noop = SeedingPolicy.apply(row, now())
    assert StubAdapter.pauses() == []
    refute stamp(row)
  end

  test "never pauses a stamped row again" do
    row = row(%{metadata: %{"seeding_goal_reached_at" => "2031-01-01T00:00:00Z"}})
    assert :noop = SeedingPolicy.apply(row, now())
    assert StubAdapter.pauses() == []
  end

  test "remove mode leaves imported rows to removal" do
    put_target(seed_ratio: 1.0, seed_goal_action: :remove)
    row = row(%{imported_at: DateTime.utc_now()})
    assert :left_to_removal = SeedingPolicy.apply(row, now())
    assert StubAdapter.pauses() == []
    refute stamp(row)
  end

  test "remove mode pauses an imported row with unresolved files, which removal skips" do
    put_target(seed_ratio: 1.0, seed_goal_action: :remove)
    row = row(%{imported_at: DateTime.utc_now(), match_status: "unresolved_files"})
    assert :paused = SeedingPolicy.apply(row, now())
    assert StubAdapter.pauses() == [row.download_client_id]
    assert stamp(row)
  end

  test "remove mode pauses an unimported row" do
    put_target(seed_ratio: 1.0, seed_goal_action: :remove)
    assert :paused = SeedingPolicy.apply(row(), now())
  end

  test "never pauses a private row whose tracker terms are unknown" do
    put_target(seed_ratio: 0.0)
    row = row(%{ratio: 50.0, metadata: %{"tracker_terms" => %{"private" => true}}})
    assert :noop = SeedingPolicy.apply(row, now())
    assert StubAdapter.pauses() == []
    refute stamp(row)
  end

  test "waits for the tracker minimum when it is longer than the target" do
    row = row(%{ratio: 1.2, metadata: %{"tracker_terms" => %{"minimum_ratio" => 3.0}}})
    assert :noop = SeedingPolicy.apply(row, now())
    assert :paused = SeedingPolicy.apply(%{row | ratio: 3.0}, now())
  end

  test "no target means no action" do
    BuiltIn.clear_runtime()
    row = row(%{metadata: %{"tracker_terms" => %{"minimum_ratio" => 0.5}}})
    assert :noop = SeedingPolicy.apply(row, now())
    assert StubAdapter.pauses() == []
  end

  test "a failed pause leaves no stamp" do
    StubAdapter.fail!()
    row = row()
    assert {:error, _} = SeedingPolicy.apply(row, now())
    refute stamp(row)
  end

  test "a row not seeding right now is left alone" do
    assert :noop = SeedingPolicy.apply(row(%{status: "paused"}), now())
    assert StubAdapter.pauses() == []
  end

  test "Policies.run skips other clients and survives a raising row" do
    other = %{row() | download_client: "Other"}
    broken = %{row() | download_client_id: nil, metadata: :boom}
    good = row()

    assert :ok = Policies.run([other, broken, good], now())

    assert StubAdapter.pauses() == [good.download_client_id]
    assert stamp(good)
    refute stamp(other)
  end
end
