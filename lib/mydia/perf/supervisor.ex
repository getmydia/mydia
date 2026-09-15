defmodule Mydia.Perf.Supervisor do
  @moduledoc """
  Runs Peep and `Mydia.Perf.Flusher`, or nothing when `Mydia.Perf.enabled?/0`
  is false.

  `:rest_for_one` restarts the flusher whenever Peep restarts, so the flusher's
  baseline never refers to a Peep that no longer exists. The flusher starts
  after Peep and therefore stops first, while Peep can still answer its final
  snapshot.
  """
  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    if Mydia.Perf.enabled?() do
      Supervisor.init(children(), strategy: :rest_for_one)
    else
      :ignore
    end
  end

  @doc false
  def children do
    [
      {Peep, name: Mydia.Perf.Peep, metrics: Mydia.Perf.Metrics.all()},
      Mydia.Perf.Flusher
    ]
  end
end
