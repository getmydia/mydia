defmodule MetadataRelay.PlayerLogs.SweepTest do
  use ExUnit.Case, async: false

  import Ecto.Query
  import MetadataRelay.PlayerLogsHelpers

  alias MetadataRelay.{PlayerLogs, Repo}
  alias MetadataRelay.PlayerLogs.{Chunk, Device, Report, Store}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    use_tmp_logs_dir()
    :ok
  end

  defp days_ago(days),
    do: DateTime.utc_now() |> DateTime.add(-days * 86_400) |> DateTime.truncate(:second)

  defp backdate_chunks(where_kind, days) do
    Repo.update_all(from(c in Chunk, where: c.kind == ^where_kind),
      set: [inserted_at: days_ago(days)]
    )
  end

  defp file_exists?(chunk), do: File.exists?(Path.join(Store.root(), chunk.path))

  test "deletes stream chunks older than 14 days, with their files" do
    {:ok, :stream} = PlayerLogs.ingest(batch())
    [old] = Repo.all(Chunk)
    backdate_chunks("stream", 15)
    {:ok, :stream} = PlayerLogs.ingest(batch())

    :ok = PlayerLogs.sweep()

    assert [fresh] = Repo.all(Chunk)
    assert fresh.id != old.id
    refute file_exists?(old)
    assert file_exists?(fresh)
  end

  test "keeps a report's chunks past 14 days and deletes the report after 90" do
    {:ok, {:report, code}} = PlayerLogs.ingest(batch(meta: [kind: "report"]))
    backdate_chunks("report", 20)
    Repo.update_all(from(r in Report, where: r.code == ^code), set: [inserted_at: days_ago(20)])

    :ok = PlayerLogs.sweep()
    assert [_chunk] = PlayerLogs.chunks_for_report(code)

    Repo.update_all(from(r in Report, where: r.code == ^code), set: [inserted_at: days_ago(91)])
    [chunk] = PlayerLogs.chunks_for_report(code)

    :ok = PlayerLogs.sweep()

    assert Repo.get(Report, code) == nil
    assert PlayerLogs.chunks_for_report(code) == []
    refute file_exists?(chunk)
  end

  test "deletes a device idle for 90 days once it has no chunks" do
    {:ok, :stream} = PlayerLogs.ingest(batch())
    Repo.update_all(Device, set: [last_seen_at: days_ago(91)])

    :ok = PlayerLogs.sweep()
    assert Repo.get(Device, device_id()), "a device with chunks stays"

    Repo.delete_all(Chunk)
    :ok = PlayerLogs.sweep()
    assert Repo.get(Device, device_id()) == nil
  end

  test "removes files with no index row once they are an hour old" do
    {:ok, _bytes} = Store.write("stream/orphan/2026-01-01/1-aaaaaaaa.ndjson.gz", ["{}\n"])
    {:ok, _bytes} = Store.write("stream/orphan/2026-01-01/2-bbbbbbbb.ndjson.gz", ["{}\n"])
    old = Path.join(Store.root(), "stream/orphan/2026-01-01/1-aaaaaaaa.ndjson.gz")
    File.touch!(old, System.os_time(:second) - 7_200)

    :ok = PlayerLogs.sweep()

    refute File.exists?(old)
    assert File.exists?(Path.join(Store.root(), "stream/orphan/2026-01-01/2-bbbbbbbb.ndjson.gz"))
  end

  test "the cap evicts the oldest stream chunks before any report chunk" do
    for _ <- 1..3, do: {:ok, :stream} = PlayerLogs.ingest(batch())
    {:ok, {:report, code}} = PlayerLogs.ingest(batch(meta: [kind: "report"]))
    [oldest | _] = Repo.all(from(c in Chunk, where: c.kind == "stream", order_by: c.id))

    put_logs_config(:max_bytes, PlayerLogs.total_bytes() - 1)
    :ok = PlayerLogs.enforce_cap()

    remaining = Repo.all(Chunk)
    refute Enum.any?(remaining, &(&1.id == oldest.id))
    assert Enum.any?(remaining, &(&1.report_code == code))
    assert PlayerLogs.total_bytes() <= PlayerLogs.config(:max_bytes) * 0.9
  end

  test "the cap reaches report chunks once no stream chunk is left" do
    {:ok, {:report, first}} = PlayerLogs.ingest(batch(meta: [kind: "report"]))
    {:ok, {:report, second}} = PlayerLogs.ingest(batch(meta: [kind: "report"]))

    put_logs_config(:max_bytes, PlayerLogs.total_bytes() - 1)
    :ok = PlayerLogs.enforce_cap()

    assert PlayerLogs.chunks_for_report(first) == []
    assert [_chunk] = PlayerLogs.chunks_for_report(second)
  end

  test "ingest over the cap stores the batch and then applies the cap" do
    put_logs_config(:max_bytes, 1)

    assert {:ok, :stream} = PlayerLogs.ingest(batch())
    assert Repo.all(Chunk) == []
  end
end
