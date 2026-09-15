defmodule Mydia.Perf.ReportRow do
  @moduledoc """
  One metric and tag set in `Mydia.Perf.report/1`. Percentiles and `max_ms` are
  bucket upper bounds, within Peep's roughly 10% bucket width, and are
  `:infinity` when they fall above the metric's `max_value`.
  """

  @enforce_keys [:metric, :tags, :count, :total_ms, :mean_ms, :p50_ms, :p95_ms, :max_ms]
  defstruct @enforce_keys

  @type ms :: float() | :infinity

  @type t :: %__MODULE__{
          metric: String.t(),
          tags: String.t(),
          count: pos_integer(),
          total_ms: float(),
          mean_ms: float(),
          p50_ms: ms(),
          p95_ms: ms(),
          max_ms: ms()
        }
end
