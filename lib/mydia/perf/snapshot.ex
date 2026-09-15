defmodule Mydia.Perf.Snapshot do
  @moduledoc """
  Turns Peep's cumulative distributions into the deltas `Mydia.Perf.Flusher`
  persists.

  Peep never resets. For every metric and tag set, `Peep.get_all_metrics/1`
  returns the count in each bucket and the running sum since Peep started, so a
  window's values are the current snapshot minus the snapshot taken when the
  window opened.
  """

  @typedoc "Distribution values keyed by `{dotted metric name, tags}`."
  @type t :: %{optional({String.t(), map()}) => map()}

  @type delta :: %{
          metric: String.t(),
          tags: String.t(),
          count: pos_integer(),
          sum_us: integer(),
          buckets: %{optional(String.t()) => pos_integer()}
        }

  @doc "Normalizes `Peep.get_all_metrics/1` output. `nil`, Peep not running, is empty."
  @spec normalize(map() | nil) :: t()
  def normalize(nil), do: %{}

  def normalize(metrics) when is_map(metrics) do
    for {%Telemetry.Metrics.Distribution{name: name}, by_tags} <- metrics,
        {tags, values} <- by_tags,
        into: %{} do
      {{Enum.join(name, "."), tags}, values}
    end
  end

  @doc "What `current` holds beyond `baseline`, one entry per key that saw events."
  @spec deltas(t(), t()) :: [delta()]
  def deltas(current, baseline) do
    for {{metric, tags} = key, values} <- current,
        delta = subtract(values, Map.get(baseline, key, %{})),
        delta.count > 0 do
      Map.merge(delta, %{metric: metric, tags: encode_tags(tags)})
    end
  end

  @doc "Canonical text for a tag map: keys sorted, `key=value` joined by commas."
  @spec encode_tags(map()) :: String.t()
  def encode_tags(tags) do
    tags
    |> Enum.map(fn {key, value} -> {to_string(key), to_string(value)} end)
    |> Enum.sort()
    |> Enum.map_join(",", fn {key, value} -> key <> "=" <> value end)
  end

  defp subtract(values, base) do
    diffs =
      for {bound, count} <- values, bound != :sum do
        {bound, count - Map.get(base, bound, 0)}
      end

    if Enum.any?(diffs, fn {_bound, diff} -> diff < 0 end) do
      # The baseline came from a Peep that has since restarted.
      subtract(values, %{})
    else
      buckets = for {bound, diff} <- diffs, diff > 0, into: %{}, do: {encode_bound(bound), diff}

      %{
        count: buckets |> Map.values() |> Enum.sum(),
        sum_us: Map.get(values, :sum, 0) - Map.get(base, :sum, 0),
        buckets: buckets
      }
    end
  end

  defp encode_bound(:infinity), do: "inf"
  defp encode_bound(bound) when is_binary(bound), do: bound
end
