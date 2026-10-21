defmodule Mydia.Jobs.ImportQueueReconciler do
  @moduledoc """
  Re-enqueues the import queue drains that were in flight when the previous
  node died.

  `ApplyImportCandidates`, `RematchImportCandidates` and
  `DeleteImportCandidates` drain candidates marked with `queued_op`. A drain
  killed mid-way leaves its Oban row `executing` and its candidates marked, and
  nothing else would ever enqueue another drain.

  The supervision position is the same as `Mydia.Jobs.ImportRunReconciler`'s,
  and so is the argument for it: after `Ecto.Migrator`, before the Oban child,
  so a same-node `executing` row is provably an orphan. See that module for the
  reasoning. The work lives in `Mydia.ImportCandidates.requeue_stranded/0`,
  which swallows and logs its own failures.

  Does its work synchronously in `init/1` and returns `:ignore`.
  """

  use GenServer

  alias Mydia.ImportCandidates

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ImportCandidates.requeue_stranded()
    :ignore
  end
end
