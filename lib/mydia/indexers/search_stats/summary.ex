defmodule Mydia.Indexers.SearchStats.Summary do
  @moduledoc """
  One indexer's calls under one engine over a window.

  Durations cover every attempt, failures included: a timed-out tracker is
  exactly the latency a user waits through. `avg_results` covers successful
  searches only. Percentiles are nearest-rank.
  """

  defstruct [
    :indexer_id,
    :engine,
    attempts: 0,
    successes: 0,
    timeouts: 0,
    p50_ms: nil,
    p90_ms: nil,
    avg_results: nil
  ]

  @type t :: %__MODULE__{}

  @timeouts ["timeout", "deadline"]

  @doc "Builds a summary from `{indexer_id, engine, outcome, duration_ms, result_count}` rows."
  @spec build(String.t(), String.t() | nil, [tuple()]) :: t()
  def build(indexer_id, engine, rows) do
    durations = rows |> Enum.map(&elem(&1, 3)) |> Enum.sort()
    ok_rows = Enum.filter(rows, &(elem(&1, 2) == "ok"))

    %__MODULE__{
      indexer_id: indexer_id,
      engine: engine,
      attempts: length(rows),
      successes: length(ok_rows),
      timeouts: Enum.count(rows, &(elem(&1, 2) in @timeouts)),
      p50_ms: percentile(durations, 50),
      p90_ms: percentile(durations, 90),
      avg_results: average(Enum.map(ok_rows, &elem(&1, 4)))
    }
  end

  @spec success_rate(t()) :: float() | nil
  def success_rate(%__MODULE__{attempts: 0}), do: nil

  def success_rate(%__MODULE__{successes: successes, attempts: attempts}),
    do: successes / attempts

  # Integer arithmetic for ceil(percent * n / 100), so no float rounding
  # moves the rank.
  defp percentile([], _percent), do: nil

  defp percentile(sorted, percent) do
    rank = div(percent * length(sorted) + 99, 100)
    Enum.at(sorted, max(rank - 1, 0))
  end

  defp average([]), do: nil
  defp average(values), do: Float.round(Enum.sum(values) / length(values), 1)
end
