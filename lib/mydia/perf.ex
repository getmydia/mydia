defmodule Mydia.Perf do
  @moduledoc """
  Persisted performance metrics.

  `Mydia.Perf.Supervisor` runs Peep with `Mydia.Perf.Metrics.all/0`, and
  `Mydia.Perf.Flusher` writes hourly rows to `perf_rollups`. This module reads
  them back. On a release:

      bin/mydia rpc 'Mydia.Perf.print_report(since: ~D[2026-09-15], order_by: :p95)'
  """

  import Ecto.Query

  alias Mydia.Perf.ReportRow
  alias Mydia.Perf.Rollup
  alias Mydia.Repo

  @self_caller "caller=Mydia.Perf."

  @doc """
  Ranks recorded metrics.

  Options: `:since` and `:until` (`DateTime` or `Date`, a `Date` meaning 00:00
  UTC; default the last 24 hours), `:metric` (a name prefix such as
  `"phoenix.live_view"`), `:order_by` (`:total`, `:p95` or `:count`; default
  `:total`), `:limit` (default 40). Rows for the flusher's own queries are left
  out.
  """
  @spec report(keyword()) :: [ReportRow.t()]
  def report(opts \\ []) do
    now = DateTime.utc_now()
    since = opts |> Keyword.get(:since, DateTime.add(now, -86_400, :second)) |> to_datetime()
    until = opts |> Keyword.get(:until, now) |> to_datetime()
    prefix = Keyword.get(opts, :metric)

    Rollup
    |> where([r], r.hour >= ^Rollup.hour_of(since) and r.hour <= ^until and r.count > 0)
    |> select([r], {r.metric, r.tags, r.count, r.sum_us, r.buckets})
    |> Repo.all()
    |> Enum.filter(fn {metric, tags, _count, _sum, _buckets} ->
      metric_matches?(metric, prefix) and not String.starts_with?(tags, @self_caller)
    end)
    |> Enum.group_by(fn {metric, tags, _count, _sum, _buckets} -> {metric, tags} end)
    |> Enum.map(fn {{metric, tags}, rows} -> build_row(metric, tags, rows) end)
    |> Enum.sort_by(sort_key(Keyword.get(opts, :order_by, :total)), :desc)
    |> Enum.take(Keyword.get(opts, :limit, 40))
  end

  @doc "Prints `report/1` as a fixed-width table."
  @spec print_report(keyword()) :: :ok
  def print_report(opts \\ []) do
    IO.puts(format_line(["count", "total ms", "mean", "p50", "p95", "max"], "metric", "tags"))

    for row <- report(opts) do
      numbers = [row.count, row.total_ms, row.mean_ms, row.p50_ms, row.p95_ms, row.max_ms]
      IO.puts(format_line(numbers, row.metric, row.tags))
    end

    :ok
  end

  defp to_datetime(%DateTime{} = datetime), do: DateTime.truncate(datetime, :second)
  defp to_datetime(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")

  defp metric_matches?(_metric, nil), do: true
  defp metric_matches?(metric, prefix), do: String.starts_with?(metric, prefix)

  defp build_row(metric, tags, rows) do
    count = rows |> Enum.map(&elem(&1, 2)) |> Enum.sum()
    sum_us = rows |> Enum.map(&elem(&1, 3)) |> Enum.sum()
    buckets = rows |> Enum.map(&elem(&1, 4)) |> merge_buckets()
    total_ms = sum_us / 1000

    %ReportRow{
      metric: metric,
      tags: tags,
      count: count,
      total_ms: total_ms,
      mean_ms: total_ms / count,
      p50_ms: percentile(buckets, count, 0.50),
      p95_ms: percentile(buckets, count, 0.95),
      max_ms: buckets |> List.last() |> elem(0) |> to_ms()
    }
  end

  # Sorted ascending `{upper bound in microseconds | :infinity, count}` pairs.
  # Numbers sort before atoms, so `:infinity` lands last.
  defp merge_buckets(encoded) do
    encoded
    |> Enum.map(&Jason.decode!/1)
    |> Enum.reduce(%{}, &Map.merge(&2, &1, fn _bound, left, right -> left + right end))
    |> Enum.map(fn {bound, count} -> {parse_bound(bound), count} end)
    |> Enum.sort_by(fn {bound, _count} -> bound end)
  end

  defp parse_bound("inf"), do: :infinity

  defp parse_bound(bound) do
    {value, _rest} = Float.parse(bound)
    value
  end

  defp percentile(buckets, count, quantile) do
    rank = max(ceil(quantile * count), 1)

    found =
      Enum.reduce_while(buckets, 0, fn {bound, n}, seen ->
        if seen + n >= rank, do: {:halt, {:bound, bound}}, else: {:cont, seen + n}
      end)

    case found do
      {:bound, bound} -> to_ms(bound)
      _seen -> :infinity
    end
  end

  defp to_ms(:infinity), do: :infinity
  defp to_ms(microseconds), do: microseconds / 1000

  defp sort_key(:total), do: & &1.total_ms
  defp sort_key(:count), do: & &1.count
  defp sort_key(:p95), do: & &1.p95_ms

  defp format_line(numbers, metric, tags) do
    columns = Enum.map_join(numbers, " ", &(&1 |> format_value() |> String.pad_leading(10)))
    "#{columns}  #{metric}  #{tags}"
  end

  defp format_value(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1)
  defp format_value(:infinity), do: "inf"
  defp format_value(value), do: to_string(value)
end
