defmodule Mydia.Perf.MetricsTest do
  use Mydia.DataCase, async: false

  alias Mydia.Perf.Metrics

  @peep :perf_metrics_test

  setup do
    start_supervised!({Peep, name: @peep, metrics: Metrics.all()})
    :ok
  end

  defp values(name, tags) do
    @peep
    |> Peep.get_all_metrics()
    |> Enum.find_value(fn {metric, by_tags} -> if metric.name == name, do: by_tags[tags] end)
  end

  defp bucket_count(values) do
    values
    |> Enum.reject(fn {key, _count} -> key == :sum end)
    |> Enum.map(fn {_key, count} -> count end)
    |> Enum.sum()
  end

  test "Peep accepts every metric" do
    assert Enum.all?(Metrics.all(), &Peep.allow_metric?/1)
  end

  test "a span is recorded in microseconds under its tags" do
    :telemetry.execute(
      [:mydia, :p2p, :request, :stop],
      %{duration: System.convert_time_unit(5, :millisecond, :native)},
      %{kind: "graphql"}
    )

    values = values([:mydia, :p2p, :request, :stop, :duration], %{kind: "graphql"})
    assert values[:sum] == 5_000
    assert bucket_count(values) == 1
  end

  test "a real query is recorded under its caller and table" do
    {:ok, _count} = Mydia.PerfQueryProbe.count_users()

    values =
      values(
        [:mydia, :repo, :query, :total_time],
        %{caller: "Mydia.PerfQueryProbe.count_users/0", source: "users"}
      )

    assert bucket_count(values) >= 1
  end
end
