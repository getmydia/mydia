defmodule Mydia.PerfTest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureIO

  alias Mydia.Perf
  alias Mydia.Perf.ReportRow
  alias Mydia.Perf.Rollup
  alias Mydia.Repo

  @mount "phoenix.live_view.mount.stop.duration"
  @window [since: ~U[2026-09-15 00:00:00Z], until: ~U[2026-09-16 00:00:00Z]]

  # 100 events: 50 at <= 1ms, 45 at <= 2ms, 5 at <= 10ms, 200ms in total.
  @buckets %{"1000.0" => 50, "2000.0" => 45, "10000.0" => 5}

  defp rollup(attrs) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    row =
      Map.merge(
        %{
          id: Ecto.UUID.generate(),
          hour: ~U[2026-09-15 10:00:00Z],
          boot_id: "boot-a",
          metric: @mount,
          tags: "connected=true,view=MydiaWeb.MediaLive.Index",
          count: 100,
          sum_us: 200_000,
          buckets: Jason.encode!(@buckets),
          inserted_at: now,
          updated_at: now
        },
        attrs
      )

    Repo.insert_all(Rollup, [row])
  end

  describe "report/1" do
    test "one row: totals, mean, and percentiles from buckets" do
      rollup(%{})

      assert [
               %ReportRow{
                 metric: @mount,
                 tags: "connected=true,view=MydiaWeb.MediaLive.Index",
                 count: 100,
                 total_ms: 200.0,
                 mean_ms: 2.0,
                 p50_ms: 1.0,
                 p95_ms: 2.0,
                 max_ms: 10.0
               }
             ] = Perf.report(@window)
    end

    test "merges rows across boots and hours" do
      rollup(%{boot_id: "boot-a", hour: ~U[2026-09-15 10:00:00Z]})
      rollup(%{boot_id: "boot-b", hour: ~U[2026-09-15 11:00:00Z]})

      assert [%ReportRow{count: 200, total_ms: 400.0, p50_ms: 1.0, p95_ms: 2.0}] =
               Perf.report(@window)
    end

    test "above-max events report as infinity" do
      rollup(%{count: 2, buckets: Jason.encode!(%{"1000.0" => 1, "inf" => 1})})

      assert [%ReportRow{p50_ms: 1.0, p95_ms: :infinity, max_ms: :infinity}] =
               Perf.report(@window)
    end

    test "filters by metric prefix" do
      rollup(%{})
      rollup(%{metric: "oban.job.stop.duration", tags: "state=success,worker=Mydia.Jobs.Example"})

      assert [%ReportRow{metric: "oban.job.stop.duration"}] =
               Perf.report(Keyword.put(@window, :metric, "oban."))
    end

    test "orders by total, count or p95" do
      rollup(%{tags: "view=Heavy", count: 10, sum_us: 900_000})
      rollup(%{tags: "view=Frequent", count: 100, sum_us: 200_000})

      assert ["view=Heavy", "view=Frequent"] = @window |> Perf.report() |> Enum.map(& &1.tags)

      assert ["view=Frequent", "view=Heavy"] =
               @window |> Keyword.put(:order_by, :count) |> Perf.report() |> Enum.map(& &1.tags)

      rollup(%{
        tags: "view=Spiky",
        count: 20,
        sum_us: 20_000,
        buckets: Jason.encode!(%{"50000.0" => 20})
      })

      assert ["view=Spiky" | _] =
               @window |> Keyword.put(:order_by, :p95) |> Perf.report() |> Enum.map(& &1.tags)
    end

    test "only reads hours inside the window" do
      rollup(%{hour: ~U[2026-09-14 09:00:00Z]})

      assert Perf.report(@window) == []
      assert [_row] = Perf.report(since: ~D[2026-09-14], until: ~D[2026-09-15])
    end

    test "leaves out the flusher's own queries" do
      rollup(%{
        metric: "mydia.repo.query.total_time",
        tags: "caller=Mydia.Perf.Flusher.upsert/1,source=perf_rollups"
      })

      assert Perf.report(@window) == []
    end

    test "respects the limit" do
      for n <- 1..3, do: rollup(%{tags: "view=V#{n}"})

      assert length(Perf.report(Keyword.put(@window, :limit, 2))) == 2
    end
  end

  describe "print_report/1" do
    test "prints a header and one line per row" do
      rollup(%{})

      output = capture_io(fn -> assert :ok = Perf.print_report(@window) end)

      assert output =~ "count"
      assert output =~ "p95"
      assert output =~ @mount
      assert output =~ "view=MydiaWeb.MediaLive.Index"
    end
  end
end
