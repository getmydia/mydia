defmodule MetadataRelay.PlayerLogsTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import MetadataRelay.PlayerLogsHelpers

  alias MetadataRelay.{PlayerLogs, Repo}
  alias MetadataRelay.PlayerLogs.{Chunk, Device, Report, Store}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    %{logs_dir: use_tmp_logs_dir()}
  end

  test "a stream batch becomes one gzipped file and one index row" do
    batch =
      batch(
        records: [
          record_map(%{"t" => 1_000, "sid" => "s1"}),
          record_map(%{"t" => 3_000, "sid" => "s1"}),
          record_map(%{"t" => 2_000, "sid" => "s2"})
        ]
      )

    assert {:ok, :stream} = PlayerLogs.ingest(batch)

    [chunk] = Repo.all(Chunk)
    assert chunk.kind == "stream"
    assert chunk.device_id == device_id()
    assert {chunk.first_t, chunk.last_t, chunk.line_count} == {1_000, 3_000, 3}
    assert chunk.report_code == nil
    assert String.starts_with?(chunk.path, "stream/#{device_id()}/")
    assert chunk.bytes == File.stat!(Path.join(Store.root(), chunk.path)).size

    stored = chunk.path |> Store.stream_lines() |> Enum.map(&Jason.decode!/1)
    assert Enum.map(stored, & &1["t"]) == [1_000, 3_000, 2_000]

    assert chunk.sessions |> Jason.decode!() |> Enum.sort_by(& &1["sid"]) == [
             %{"sid" => "s1", "first" => 1_000, "last" => 3_000, "n" => 2},
             %{"sid" => "s2", "first" => 2_000, "last" => 2_000, "n" => 1}
           ]
  end

  test "records the device and what it sent today" do
    assert {:ok, :stream} = PlayerLogs.ingest(batch(size: 1_000))
    assert {:ok, :stream} = PlayerLogs.ingest(batch(size: 500))

    device = Repo.get!(Device, device_id())
    assert device.name == "Work MacBook"
    assert device.platform == "macos"
    assert device.app_version == "0.15.0"
    assert device.bytes_today == 1_500
    assert device.bytes_day == Date.utc_today()
  end

  test "refuses a batch past the daily quota until the next UTC day" do
    late = ~U[2026-09-22 23:59:00Z]

    assert {:ok, :stream} = PlayerLogs.ingest(batch(size: 50 * 1024 * 1024 - 10), late)
    assert {:error, {:quota_exceeded, 60}} = PlayerLogs.ingest(batch(size: 11), late)
    assert {:ok, :stream} = PlayerLogs.ingest(batch(size: 11), ~U[2026-09-23 00:00:01Z])
  end

  test "a report gets a code, and follow-ups from the same device join it" do
    assert {:ok, {:report, code}} =
             PlayerLogs.ingest(batch(meta: [kind: "report", note: "Stutters after seeking"]))

    assert code =~ ~r/\ALOG-[0-9A-HJKMNP-TV-Z]{6}\z/

    assert {:ok, {:report, ^code}} =
             PlayerLogs.ingest(batch(meta: [kind: "report", report: code, note: "ignored"]))

    assert %Report{note: "Stutters after seeking", device_id: device} = Repo.get!(Report, code)
    assert device == device_id()

    chunks = PlayerLogs.chunks_for_report(code)
    assert length(chunks) == 2
    assert Enum.all?(chunks, &String.starts_with?(&1.path, "reports/#{code}/"))
    assert Enum.all?(chunks, &(&1.kind == "report"))
  end

  test "a follow-up is refused from another device, after ten minutes, or for an unknown code" do
    {:ok, {:report, code}} = PlayerLogs.ingest(batch(meta: [kind: "report"]))
    other = "0b7d3c2e-1a4f-4e6b-9c8d-2f3e4a5b6c7d"

    assert {:error, :unknown_report} =
             PlayerLogs.ingest(batch(meta: [kind: "report", report: code, device_id: other]))

    eleven_minutes_ago = DateTime.utc_now() |> DateTime.add(-660) |> DateTime.truncate(:second)

    Repo.update_all(from(r in Report, where: r.code == ^code),
      set: [inserted_at: eleven_minutes_ago]
    )

    assert {:error, :unknown_report} =
             PlayerLogs.ingest(batch(meta: [kind: "report", report: code]))

    assert {:error, :unknown_report} =
             PlayerLogs.ingest(batch(meta: [kind: "report", report: "LOG-000000"]))
  end

  test "a failed write leaves no index row", %{logs_dir: dir} do
    File.mkdir_p!(Path.dirname(dir))
    File.write!(dir, "a file where the directory should be")

    assert {:error, {:storage, _reason}} = PlayerLogs.ingest(batch())
    assert Repo.all(Chunk) == []
    assert Repo.get(Device, device_id()) == nil
  end

  describe "concurrent usage charges" do
    # A large enough batch that store_chunk's real file I/O and gzip work
    # (between check_quota's read and record_usage's write) gives both
    # concurrent ingest/2 calls room to interleave.
    defp wide_records(count), do: for(i <- 1..count, do: record_map(%{"t" => 1_000 + i}))

    defp ingest_concurrently(id, records, size) do
      parent = self()

      Task.async(fn ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, parent, self())
        PlayerLogs.ingest(batch(meta: [device_id: id], records: records, size: size))
      end)
    end

    test "two concurrent uploads from the same device both count against bytes_today" do
      records = wide_records(2_000)

      [task_a, task_b] = [
        ingest_concurrently(device_id(), records, 300_000),
        ingest_concurrently(device_id(), records, 300_000)
      ]

      assert {:ok, :stream} = Task.await(task_a, 10_000)
      assert {:ok, :stream} = Task.await(task_b, 10_000)

      device = Repo.get!(Device, device_id())

      assert device.bytes_today == 600_000,
             "a charge computed from a stale `used` read must add, not overwrite: got #{device.bytes_today}"
    end

    test "two concurrent first uploads from a brand new device do not raise" do
      id = Ecto.UUID.generate()
      records = wide_records(2_000)

      [task_a, task_b] = [
        ingest_concurrently(id, records, 1_000),
        ingest_concurrently(id, records, 1_000)
      ]

      assert {:ok, :stream} = Task.await(task_a, 10_000)
      assert {:ok, :stream} = Task.await(task_b, 10_000)

      device = Repo.get!(Device, id)
      assert device.bytes_today == 2_000
    end
  end
end
