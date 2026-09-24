defmodule Mydia.Metrics.DefinitionsTest do
  use ExUnit.Case, async: true

  alias Mydia.Metrics.Definitions

  test "every metric is namespaced under mydia" do
    for metric <- Definitions.all() do
      assert [:mydia | _] = metric.name
    end
  end

  test "every distribution sets explicit coarse buckets" do
    for %Telemetry.Metrics.Distribution{} = metric <- Definitions.all() do
      assert metric.reporter_options[:peep_bucket_calculator] in [
               Mydia.Metrics.Buckets.Http,
               Mydia.Metrics.Buckets.Job
             ]
    end
  end
end
