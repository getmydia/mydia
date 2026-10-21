defmodule Mydia.ImportCandidates.Requeue do
  @moduledoc false

  import Ecto.Query

  require Logger

  alias Mydia.ImportCandidates.Store
  alias Mydia.Jobs.{ApplyImportCandidates, DeleteImportCandidates, RematchImportCandidates}
  alias Mydia.Library.ImportCandidate
  alias Mydia.Repo

  @workers %{
    "accept" => ApplyImportCandidates,
    "rematch" => RematchImportCandidates,
    "delete" => DeleteImportCandidates
  }

  @worker_names Enum.map(Map.values(@workers), &inspect/1)
  @pending_states ~w(available scheduled retryable)

  @doc """
  Re-enqueues the drains a dead node left behind.

  A drain job that was `executing` when the node died stays `executing`
  forever (see `Mydia.Jobs.ImportRunReconciler` for why nothing rescues it),
  and the candidates it was draining keep their `queued_op`. This retires the
  orphaned rows and enqueues one fresh drain per `(library path, queued_op)`
  that has queued candidates and no pending job.

  Only safe before this node's Oban queues start, which is where
  `Mydia.Jobs.ImportQueueReconciler` calls it from.
  """
  @spec requeue_stranded() :: {:ok, %{retired: non_neg_integer(), enqueued: non_neg_integer()}}
  def requeue_stranded do
    retired = retire_orphaned_drains()
    pending = pending_drains()

    enqueued =
      stranded_pairs()
      |> Enum.count(fn {library_path_id, op} ->
        enqueue_missing(library_path_id, op, pending)
      end)

    if retired > 0 or enqueued > 0 do
      Logger.warning("Requeued import queue drains left behind by an interrupted node",
        retired: retired,
        enqueued: enqueued
      )
    end

    {:ok, %{retired: retired, enqueued: enqueued}}
  rescue
    error ->
      # Boot-time work must never take the application down with it.
      Logger.error("Could not requeue stranded import queue drains: #{inspect(error)}")
      {:ok, %{retired: 0, enqueued: 0}}
  end

  # `attempted_by` is `[node, uuid]` on the Basic engine and `[node]` on Lite,
  # so only the head is portable, and it is filtered in Elixir because JSON
  # querying is not portable between SQLite and PostgreSQL.
  defp retire_orphaned_drains do
    this_node = Oban.Config.node_name()

    ids =
      Oban.Job
      |> where([j], j.worker in ^@worker_names and j.state == "executing")
      |> select([j], {j.id, j.attempted_by})
      |> Repo.all()
      |> Enum.flat_map(fn
        {id, [^this_node | _]} -> [id]
        _ -> []
      end)

    case ids do
      [] ->
        0

      ids ->
        {count, _} =
          Oban.Job
          |> where([j], j.id in ^ids)
          |> Repo.update_all(set: [state: "cancelled", cancelled_at: DateTime.utc_now()])

        count
    end
  end

  defp pending_drains do
    Oban.Job
    |> where([j], j.worker in ^@worker_names and j.state in ^@pending_states)
    |> select([j], {j.worker, j.args})
    |> Repo.all()
    |> MapSet.new(fn {worker, args} -> {worker, args["library_path_id"]} end)
  end

  defp stranded_pairs do
    ImportCandidate
    |> where([c], not is_nil(c.queued_op))
    |> select([c], {c.library_path_id, c.queued_op})
    |> distinct(true)
    |> Repo.all()
  end

  # Returns true only when a job was actually inserted.
  defp enqueue_missing(library_path_id, op, pending) do
    case Map.fetch(@workers, op) do
      {:ok, worker} ->
        not MapSet.member?(pending, {inspect(worker), library_path_id}) and
          match?({:ok, _}, Store.enqueue(worker, library_path_id))

      :error ->
        Logger.warning("Skipping import candidates with an unknown queued_op",
          queued_op: op,
          library_path_id: library_path_id
        )

        false
    end
  end
end
