defmodule Mydia.Library.ImportRuns do
  @moduledoc """
  Owns the lifecycle of import runs: starting, querying, updating and stopping them.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Mydia.Repo
  alias Mydia.Library.ImportRun

  @doc """
  Starts an import run for a library path.

  Returns an error changeset when the path already has a run in flight. The
  guarantee is enforced by a partial unique index, so two tabs pressing Start
  simultaneously cannot both win.
  """
  @spec create_import_run(map()) :: {:ok, ImportRun.t()} | {:error, Ecto.Changeset.t()}
  def create_import_run(attrs) do
    attrs
    |> ImportRun.create_changeset()
    |> Repo.insert()
  end

  @doc """
  Starts a review-mode import run for every enabled library path that could
  hold `target` (a movie or an episode), or reuses the path's active run.

  Review mode records and matches files but never promotes, so this is safe
  to offer from an item page: it refreshes the candidates "Find file" ranks
  and imports nothing on its own.
  """
  @spec start_review_scans(Mydia.Media.MediaItem.t() | Mydia.Media.Episode.t(), term()) ::
          [ImportRun.t()]
  def start_review_scans(target, user_id) do
    types = Mydia.Library.CandidateSuggestions.compatible_library_types(target)

    Mydia.Settings.LibraryPath
    |> where([lp], lp.type in ^types and (lp.disabled == false or is_nil(lp.disabled)))
    |> Repo.all()
    |> Enum.flat_map(fn library_path ->
      case active_import_run(library_path.id) do
        %ImportRun{} = run -> [run]
        nil -> start_review_run(library_path, user_id)
      end
    end)
  end

  defp start_review_run(library_path, user_id) do
    # The run and its job commit together: a run with no job would stay
    # active forever and block every later scan of the path.
    result =
      Repo.transaction(fn ->
        with {:ok, run} <-
               create_import_run(%{
                 library_path_id: library_path.id,
                 user_id: user_id,
                 mode: :review
               }),
             {:ok, _job} <-
               %{"import_run_id" => run.id}
               |> Mydia.Jobs.ImportRun.new()
               |> Mydia.Jobs.insert() do
          run
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, run} ->
        [run]

      # Lost the one-active-run race to another starter; use theirs.
      {:error, %Ecto.Changeset{data: %ImportRun{}}} ->
        List.wrap(active_import_run(library_path.id))

      {:error, reason} ->
        Logger.warning("Failed to enqueue review scan",
          library_path_id: library_path.id,
          reason: inspect(reason)
        )

        []
    end
  end

  @doc """
  Fetches an import run by id, or nil.
  """
  @spec get_import_run(binary()) :: ImportRun.t() | nil
  def get_import_run(id), do: Repo.get(ImportRun, id)

  @doc """
  Returns the in-flight run for a library path, or nil.

  A `:stopping` run counts as in flight: the coordinator is still draining its
  current chunk and a second run would race it.
  """
  @spec active_import_run(binary()) :: ImportRun.t() | nil
  def active_import_run(library_path_id) do
    statuses = ImportRun.active_statuses()

    ImportRun
    |> where([r], r.library_path_id == ^library_path_id and r.status in ^statuses)
    |> Repo.one()
  end

  @doc """
  Returns the most recently started run for a library path, regardless of
  status, or nil if the path has never had one.

  Exists so a reload can still show what a finished, failed, or stopped run
  did, since `active_import_run/1` deliberately excludes terminal states (the
  coordinator and the single-active-run uniqueness guard both depend on that
  exclusion, so it is not widened here).
  """
  @spec last_import_run(binary()) :: ImportRun.t() | nil
  def last_import_run(library_path_id) do
    ImportRun
    |> where([r], r.library_path_id == ^library_path_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Updates progress counters or lifecycle state on a run.
  """
  @spec update_import_run(ImportRun.t(), map()) ::
          {:ok, ImportRun.t()} | {:error, Ecto.Changeset.t()}
  def update_import_run(%ImportRun{} = run, attrs) do
    run
    |> ImportRun.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns every run currently in an active status, across all library paths.

  Exists for boot reconciliation (`Mydia.Jobs.ImportRun.reconcile_interrupted_runs/0`),
  which has to sweep the whole table rather than one path at a time.
  """
  @spec list_active_import_runs() :: [ImportRun.t()]
  def list_active_import_runs do
    statuses = ImportRun.active_statuses()

    ImportRun
    |> where([r], r.status in ^statuses)
    |> Repo.all()
  end

  @doc """
  Asks a run to stop at the next chunk boundary.

  Re-reads the row first, for the same reason `import_run_stopping?/1` does:
  the caller is holding a struct read before the click, and the coordinator
  may have reached a terminal state since. `:stopping` is an active status, so
  writing it over a terminal row would lock that library path out forever with
  no worker left alive to advance it. Returns `{:error, changeset}` when the
  run is no longer running.
  """
  @spec request_import_run_stop(ImportRun.t() | binary()) ::
          {:ok, ImportRun.t()} | {:error, Ecto.Changeset.t()}
  def request_import_run_stop(%ImportRun{id: id}), do: request_import_run_stop(id)

  def request_import_run_stop(id) when is_binary(id) do
    case get_import_run(id) do
      nil ->
        {:error,
         %ImportRun{}
         |> ImportRun.changeset(%{})
         |> Ecto.Changeset.add_error(:id, "import run no longer exists")}

      run ->
        update_import_run(run, %{status: :stopping})
    end
  end

  @doc """
  Re-reads a run and reports whether a stop has been requested.

  Re-reads rather than inspecting the passed struct because the coordinator
  holds a stale copy between chunks; the whole point is to observe a write made
  by another process.
  """
  @spec import_run_stopping?(ImportRun.t() | binary()) :: boolean()
  def import_run_stopping?(%ImportRun{id: id}), do: import_run_stopping?(id)

  def import_run_stopping?(id) when is_binary(id) do
    case Repo.get(ImportRun, id) do
      %ImportRun{status: :stopping} -> true
      _ -> false
    end
  end
end
