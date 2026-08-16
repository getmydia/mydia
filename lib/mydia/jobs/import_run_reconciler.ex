defmodule Mydia.Jobs.ImportRunReconciler do
  @moduledoc """
  Releases import runs that were in flight when the previous node died.

  This is a supervision child rather than a call made after
  `Supervisor.start_link/2` returns, and the position matters more than it
  looks. It sits after `Ecto.Migrator` (the `import_runs` table has to exist)
  and before `Mydia.Application`'s Oban child, so at the moment it runs **no
  Oban queue on this node has started**. That is what makes "the job row still
  says `executing`" unambiguous: nothing local can be executing yet, so the row
  is a leftover from a boot that never finished.

  Ordering is the whole mechanism because the obvious alternatives do not work
  here:

    * `Oban.Plugins.Lifeline` measures `rescue_after` from `attempted_at`, and
      a real import runs for hours without checkpointing, so any window short
      enough to rescue a crashed run would also rescue a healthy one.
    * `Oban.Job.attempted_by` cannot identify the boot that wrote it. The Basic
      engine stores `[node, uuid]`, but the Lite engine (SQLite, which is
      Mydia's default adapter) stores `[node]` alone, and a container's node
      name is identical across restarts.

  Ordering is sufficient for a single instance, which is Mydia's deployment
  model, and the node comparison in `live_job?/3` extends it to a cluster whose
  nodes have distinct names. The case neither covers: two container replicas
  started with the *same* explicitly-set hostname produce the same
  `Oban.Config.node_name/0`, so replica B booting would read replica A's live
  `executing` row as its own leftover and release a healthy import. Per the
  engine analysis above there is nothing in `attempted_by` that could tell them
  apart on SQLite, and the run is recoverable (Start again), so this is
  documented rather than defended against.

  It does its work synchronously in `init/1` and then returns `:ignore`, the
  same shape `Mydia.Release.MigrationBackup` uses, so no process lingers.

  Failure policy matches that module: a boot-time repair is a safety net, never
  a boot requirement, so `Mydia.Jobs.ImportRun.reconcile_interrupted_runs/0`
  swallows and logs its own failures.
  """

  use GenServer

  alias Mydia.Jobs.ImportRun

  @doc false
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    ImportRun.reconcile_interrupted_runs()
    :ignore
  end
end
