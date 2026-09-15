defmodule Mydia.Perf.FlusherTest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog

  alias Mydia.Perf.Flusher
  alias Mydia.Perf.Rollup
  alias Mydia.Repo

  @peep :perf_flusher_test
  @event [:perf_flusher_test, :work, :stop]
  @metric "perf_flusher_test.work.stop.duration"

  setup do
    clock = start_supervised!({Agent, fn -> ~U[2026-09-15 10:02:00Z] end})
    %{clock: clock}
  end

  defp start_peep do
    metric =
      Telemetry.Metrics.distribution(@metric, unit: {:native, :microsecond}, tags: [:kind])

    start_supervised!({Peep, name: @peep, metrics: [metric]}, id: :peep)
  end

  defp start_flusher(clock) do
    opts = [
      name: nil,
      peep: @peep,
      schedule?: false,
      retention_days: 14,
      clock: fn -> Agent.get(clock, & &1) end
    ]

    pid = start_supervised!({Flusher, opts}, id: :flusher)
    Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    pid
  end

  defp work do
    duration = System.convert_time_unit(2, :millisecond, :native)
    :telemetry.execute(@event, %{duration: duration}, %{kind: "a"})
  end

  defp set_clock(clock, datetime), do: Agent.update(clock, fn _ -> datetime end)

  defp rows, do: Repo.all(from r in Rollup, order_by: [r.hour, r.boot_id])

  defp insert_row(hour, boot_id) do
    Repo.insert_all(Rollup, [
      %{
        id: Ecto.UUID.generate(),
        hour: hour,
        boot_id: boot_id,
        metric: @metric,
        tags: "kind=a",
        count: 1,
        sum_us: 1,
        buckets: ~s({"1.0":1}),
        inserted_at: hour,
        updated_at: hour
      }
    ])
  end

  test "writes the current hour's events as one row", %{clock: clock} do
    start_peep()
    pid = start_flusher(clock)
    work()
    work()

    assert :ok = Flusher.flush(pid)

    assert [row] = rows()
    assert row.hour == ~U[2026-09-15 10:00:00Z]
    assert row.metric == @metric
    assert row.tags == "kind=a"
    assert row.count == 2
    assert row.sum_us == 4_000
    assert row.buckets |> Jason.decode!() |> Map.values() |> Enum.sum() == 2
  end

  test "a second flush in the same hour replaces the row", %{clock: clock} do
    start_peep()
    pid = start_flusher(clock)
    work()
    assert :ok = Flusher.flush(pid)
    work()
    assert :ok = Flusher.flush(pid)

    assert [%Rollup{count: 2}] = rows()
  end

  test "a new hour starts a new row and leaves the old one", %{clock: clock} do
    start_peep()
    pid = start_flusher(clock)
    work()
    work()
    assert :ok = Flusher.flush(pid)

    set_clock(clock, ~U[2026-09-15 11:00:00Z])
    assert :ok = Flusher.flush(pid)
    work()
    assert :ok = Flusher.flush(pid)

    assert [
             %Rollup{hour: ~U[2026-09-15 10:00:00Z], count: 2},
             %Rollup{hour: ~U[2026-09-15 11:00:00Z], count: 1}
           ] = rows()
  end

  test "the first flush of a new hour prunes rows past retention", %{clock: clock} do
    start_peep()
    pid = start_flusher(clock)
    insert_row(~U[2026-08-31 10:00:00Z], "old")
    insert_row(~U[2026-09-02 10:00:00Z], "recent")

    set_clock(clock, ~U[2026-09-15 11:00:00Z])
    assert :ok = Flusher.flush(pid)

    assert ["recent"] = Enum.map(rows(), & &1.boot_id)
  end

  test "stopping flushes what the last flush did not write", %{clock: clock} do
    start_peep()
    start_flusher(clock)
    work()

    stop_supervised!(:flusher)

    assert [%Rollup{count: 1}] = rows()
  end

  test "a restart writes its own rows for the same hour", %{clock: clock} do
    start_peep()
    start_flusher(clock)
    work()
    work()
    stop_supervised!(:flusher)
    stop_supervised!(:peep)

    start_peep()
    pid = start_flusher(clock)
    work()
    assert :ok = Flusher.flush(pid)

    assert [1, 2] = rows() |> Enum.map(& &1.count) |> Enum.sort()
    assert rows() |> Enum.map(& &1.boot_id) |> Enum.uniq() |> length() == 2
  end

  test "a failed write keeps state, so the next flush writes full totals", %{clock: clock} do
    start_peep()
    pid = start_flusher(clock)
    work()

    Repo.query!("ALTER TABLE perf_rollups RENAME TO perf_rollups_away")
    log = capture_log(fn -> assert {:error, _reason} = Flusher.flush(pid) end)
    assert log =~ "Performance metrics flush failed"
    Repo.query!("ALTER TABLE perf_rollups_away RENAME TO perf_rollups")

    work()
    assert :ok = Flusher.flush(pid)

    assert [%Rollup{count: 2}] = rows()
  end

  test "flushes nothing when Peep is not running", %{clock: clock} do
    pid = start_flusher(clock)

    assert :ok = Flusher.flush(pid)
    assert rows() == []
  end
end
