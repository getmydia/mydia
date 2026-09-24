defmodule Mydia.Metrics.Buckets.Job do
  @moduledoc "Histogram bounds, in milliseconds, for Oban job durations."
  use Peep.Buckets.Custom,
    buckets: [100, 500, 1000, 5000, 15_000, 60_000, 300_000, 900_000, 3_600_000]
end
