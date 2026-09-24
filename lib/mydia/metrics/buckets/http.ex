defmodule Mydia.Metrics.Buckets.Http do
  @moduledoc "Histogram bounds, in milliseconds, for HTTP request durations."
  use Peep.Buckets.Custom, buckets: [5, 10, 25, 50, 100, 250, 500, 1000, 5000, 30_000]
end
