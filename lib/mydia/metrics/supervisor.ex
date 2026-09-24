defmodule Mydia.Metrics.Supervisor do
  @moduledoc """
  Runs the Peep instance behind `GET /metrics` and the two pollers that feed
  its gauges, or nothing when `Mydia.Metrics.enabled?/0` is false.

  The fast poller reads only memory (VM stats, the session registry). The slow
  poller runs database counts and reads download-client settings, so it runs
  once a minute. `:rest_for_one` restarts the pollers whenever Peep restarts.
  """
  use Supervisor

  alias Mydia.Metrics.Measurements

  @fast_period :timer.seconds(15)
  @slow_period :timer.seconds(60)

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if Mydia.Metrics.enabled?() do
      Supervisor.init(children(), strategy: :rest_for_one)
    else
      :ignore
    end
  end

  @doc false
  def children do
    [
      {Peep, name: Mydia.Metrics.Peep, metrics: Mydia.Metrics.Definitions.all()},
      poller(Mydia.Metrics.FastPoller, @fast_period, [:vm, :streaming]),
      poller(
        Mydia.Metrics.SlowPoller,
        @slow_period,
        [:build_info, :library, :downloads, :download_clients, :oban]
      )
    ]
  end

  defp poller(name, period, functions) do
    # init_delay delays the first measurement tick until one period after start.
    # This avoids errors on cold boot when the session registry or database
    # connections aren't ready yet (both come later in the supervision tree).
    Supervisor.child_spec(
      {:telemetry_poller,
       name: name,
       period: period,
       init_delay: period,
       measurements: Enum.map(functions, &{Measurements, &1, []})},
      id: name
    )
  end
end
