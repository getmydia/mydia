defmodule Mydia.Jobs.ImportRun do
  @moduledoc """
  Coordinates one user-started import of a library path.

  Two phases. Phase 1 walks the tree and commits a `media_file` row for every
  file found, in transactions of 100. It does no HTTP, so it is fast, and once
  it has run every file on disk is durably recorded. Phase 2 matches the
  outstanding files against the metadata provider in chunks, caching a
  candidate for each and, in unattended mode, linking the confident ones.

  Stopping is cooperative. Stop writes `:stopping` to the run row; the
  coordinator re-reads that row between chunks and drains. Nothing is rolled
  back, because every unit of work was committed as it completed.

  There is no resume cursor. A later run rediscovers the outstanding work by
  querying for it: phase 1 skips paths that already have rows, and phase 2
  skips files that already have a candidate or a parent. The database is the
  cursor.

  Because the database is the cursor, phase 2 terminates only if every file it
  processes leaves the outstanding set. That is `Library.FileIngest`'s progress
  contract, documented on that module; `match_loop/5` carries a no-progress
  guard as a backstop rather than as the primary mechanism.

  Crash recovery is `reconcile_interrupted_runs/0`, called once at boot.
  `Oban.Plugins.Lifeline` is deliberately not configured: its `rescue_after`
  is measured from `attempted_at`, and this job legitimately runs for hours
  without checkpointing, so any window short enough to rescue a crashed run
  would also duplicate a healthy one.
  """

  use Oban.Worker,
    queue: :imports,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      keys: [:import_run_id]
    ]

  import Ecto.Query, only: [where: 3, select: 3]

  require Logger

  alias Mydia.Library
  alias Mydia.Library.{BatchMatcher, FileIngest, ImportRun, SampleDetector, Scanner}
  alias Mydia.Metadata
  alias Mydia.{Repo, Settings}

  @scan_batch_size 100
  @match_chunk_size 50

  @doc """
  PubSub topic carrying progress for one run.
  """
  @spec progress_topic(binary()) :: String.t()
  def progress_topic(run_id), do: "import_run:#{run_id}"

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"import_run_id" => run_id}} = job) do
    case Library.get_import_run(run_id) do
      nil ->
        Logger.warning("Import run vanished before it could execute", import_run_id: run_id)
        :ok

      run ->
        execute(run, job)
    end
  end

  defp execute(run, job) do
    with :ok <- run_scan_phase(run),
         :ok <- run_match_phase(Library.get_import_run(run.id)) do
      finish(run, :done)
    else
      :stopped ->
        finish(run, :stopped)

      {:error, reason} ->
        fail(run, reason, job)
    end
  end

  # A failure is only terminal once Oban has no attempts left. Writing :failed
  # on attempt 1 tells the user the import failed while the system is still
  # about to retry it, and worse, :failed is terminal so `active_import_run/1`
  # returns nil and the user can start a SECOND coordinator for the same
  # library path while the first sits in :retryable. The partial unique index
  # guards `import_runs` rows, not Oban jobs, so nothing else would catch that.
  defp fail(run, reason, %Oban.Job{attempt: attempt, max_attempts: max_attempts}) do
    Logger.error("Import run failed",
      import_run_id: run.id,
      reason: inspect(reason),
      attempt: attempt,
      max_attempts: max_attempts
    )

    if attempt >= max_attempts do
      {:ok, updated} =
        Library.update_import_run(Library.get_import_run(run.id), %{
          status: :failed,
          phase: :finished,
          current_file: nil,
          error: format_run_error(reason)
        })

      broadcast(updated)
    else
      Logger.warning("Leaving the import run active for Oban to retry",
        import_run_id: run.id,
        attempt: attempt,
        max_attempts: max_attempts
      )
    end

    {:error, reason}
  end

  # This string is rendered verbatim in the outcome panel. The two failures
  # this coordinator raises itself carry a written sentence, so unwrap those
  # rather than showing the operator Elixir tuple syntax. Anything from
  # further down (`{:error, :not_found}` from the scanner, for instance) has
  # no sentence to unwrap and falls back to inspect/1.
  defp format_run_error({_tag, message}) when is_binary(message), do: message
  defp format_run_error(reason), do: inspect(reason)

  defp finish(run, status) do
    {:ok, updated} =
      Library.update_import_run(Library.get_import_run(run.id), %{
        status: status,
        phase: :finished,
        current_file: nil
      })

    broadcast(updated)
    :ok
  end

  ## Phase 1: scan

  @doc """
  Walks the library path and commits a `media_file` row per discovered file.

  Returns `:ok` when the whole tree was scanned, or `:stopped` if a stop was
  requested partway through. A partial scan is valid state, not an error.

  Refuses a library path whose type is not in
  `Mydia.Library.ImportRun.importable_types/0`. The start form already filters
  those out, but this is the layer that a stale bookmark or a crafted event
  cannot walk around, and it matters: nothing downstream restricts by library
  type. `Library.inbox_base_query/1` has no type filter, and
  `MediaFile.library_type_compatible?/3` has no clause for `:music`, `:books`
  or `:adult` so it falls through to `true`. An unattended run over a music
  path would send `Artist - 03 - Track.flac` to the relay and could link the
  result to a movie item.

  ## Options

    * `:after_batch` - a 0-arity function invoked once a batch has committed,
      before the next batch's stop check. Mirrors the `:progress_callback`
      seam on `Scanner.scan/2`. Defaults to a no-op. Exists so a test can make
      the stop boundary deterministic (request the stop from inside the
      callback) instead of racing a concurrent process against the loop.
  """
  @spec run_scan_phase(ImportRun.t(), keyword()) :: :ok | :stopped | {:error, term()}
  def run_scan_phase(%ImportRun{} = run, opts \\ []) do
    after_batch = Keyword.get(opts, :after_batch, fn -> :ok end)

    library_path = Settings.get_library_path!(run.library_path_id)

    with :ok <- ensure_importable(library_path) do
      extensions = Scanner.extensions_for_library_type(library_path.type)

      {:ok, _} = Library.update_import_run(run, %{phase: :scanning})

      scan_tree(run, library_path, extensions, after_batch)
    end
  end

  defp ensure_importable(library_path) do
    if ImportRun.importable_type?(library_path.type) do
      :ok
    else
      Logger.warning("Refusing to import a library path that is not movies or TV",
        library_path_id: library_path.id,
        type: library_path.type
      )

      {:error,
       {:unsupported_library_type,
        "Only movie, TV and mixed libraries can be imported. This path is a #{library_path.type} library."}}
    end
  end

  defp scan_tree(run, library_path, extensions, after_batch) do
    case Scanner.scan(library_path.path, video_extensions: extensions) do
      {:ok, scan_result} ->
        scan_result.files
        |> Enum.reject(&sample_or_extra?/1)
        |> Enum.chunk_every(@scan_batch_size)
        |> Enum.reduce_while(:ok, fn batch, _acc ->
          if Library.import_run_stopping?(run.id) do
            {:halt, :stopped}
          else
            insert_batch(batch, library_path, run)
            after_batch.()
            {:cont, :ok}
          end
        end)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sample_or_extra?(file_info) do
    not SampleDetector.skip_detection?(file_info.path) and
      SampleDetector.excluded?(SampleDetector.detect(file_info.path))
  end

  defp insert_batch(batch, library_path, run) do
    {:ok, inserted} =
      Repo.transaction(fn ->
        Enum.count(batch, fn file_info ->
          relative_path = Path.relative_to(file_info.path, library_path.path)

          case Library.get_media_file_by_relative_path(library_path.id, relative_path,
                 include_trashed: true
               ) do
            nil ->
              case Library.create_scanned_media_file(%{
                     library_path_id: library_path.id,
                     relative_path: relative_path,
                     size: file_info.size,
                     verified_at: DateTime.utc_now()
                   }) do
                {:ok, _} -> true
                {:error, _} -> false
              end

            %{trashed_at: trashed_at} = trashed when not is_nil(trashed_at) ->
              match?({:ok, _}, Library.restore_media_file(trashed))

            _existing ->
              # Already recorded by an earlier run. This is the resume path.
              false
          end
        end)
      end)

    current_run = Library.get_import_run(run.id)

    {:ok, updated} =
      Library.update_import_run(current_run, %{
        files_discovered: current_run.files_discovered + inserted
      })

    broadcast(updated)
  end

  ## Phase 2: match

  @doc """
  Matches outstanding files in chunks, caching a candidate for each.

  In `:unattended` mode a match at or above the confidence threshold is linked
  immediately. In `:review` mode nothing is linked from an external provider
  match, though a file whose show already exists locally is still associated:
  that needs no item creation and no human judgement.

  Returns `:ok` when no unmatched files remain, or `:stopped` if a stop was
  requested. Between chunks the run row is re-read, which is the only place a
  stop can take effect.

  ## Options

    * `:config` - metadata relay config, defaults to `Metadata.default_relay_config/0`.
      Lets a test point relay traffic at a local Bypass server without
      mutating the global `METADATA_RELAY_URL` env var (which would race any
      concurrently running async test that also resolves the default config).
    * `:after_chunk` - a 0-arity function invoked once a chunk has committed,
      before the next chunk's stop check. Mirrors the `:after_batch` seam on
      `run_scan_phase/2`, for the same reason: it makes the stop boundary
      deterministic in a test (request the stop from inside the callback)
      instead of racing a concurrent process against the loop. Defaults to a
      no-op.
  """
  @spec run_match_phase(ImportRun.t(), keyword()) :: :ok | :stopped | {:error, term()}
  def run_match_phase(%ImportRun{} = run, opts \\ []) do
    library_path = Settings.get_library_path!(run.library_path_id)
    config = Keyword.get(opts, :config) || Metadata.default_relay_config()
    after_chunk = Keyword.get(opts, :after_chunk, fn -> :ok end)

    {:ok, _} = Library.update_import_run(run, %{phase: :matching})

    match_loop(run, library_path, config, after_chunk)
  end

  defp match_loop(run, library_path, config, after_chunk, previous_ids \\ nil) do
    if Library.import_run_stopping?(run.id) do
      :stopped
    else
      case Library.list_unmatched_media_file_paths(library_path.id, @match_chunk_size) do
        [] ->
          :ok

        chunk ->
          ids = chunk |> Enum.map(&elem(&1, 0)) |> MapSet.new()

          if ids == previous_ids do
            no_progress(run, library_path, chunk)
          else
            process_match_chunk(chunk, run, library_path, config)
            after_chunk.()
            match_loop(run, library_path, config, after_chunk, ids)
          end
      end
    end
  end

  # Unreachable while `FileIngest`'s progress contract holds: every ingest
  # outcome leaves the file with a parent or a candidate, and either removes
  # it from this query's result set. Kept because the cost of being wrong is
  # an import that spins forever on the queue's only slot, writing NFOs on
  # every pass and permanently blocking any further import of that path.
  defp no_progress(run, library_path, chunk) do
    {_id, example} = hd(chunk)

    Logger.error("Import run made no progress on a chunk, halting",
      import_run_id: run.id,
      library_path_id: library_path.id,
      chunk_size: length(chunk),
      example_path: example
    )

    {:error,
     {:no_progress,
      "The import stopped because #{length(chunk)} file(s) could not be resolved and kept coming back, starting with #{Path.basename(example)}. This is a bug, please report it."}}
  end

  defp process_match_chunk(chunk, run, library_path, config) do
    by_path = Map.new(chunk, fn {file_id, path} -> {path, file_id} end)
    policy = policy_for(run.mode)

    results =
      by_path
      |> Map.keys()
      |> BatchMatcher.match_paths(
        config: config,
        provider: library_path.tv_metadata_source,
        on_result: fn path, _result -> note_current_file(run, path) end
      )

    linked =
      results
      |> Enum.map(fn {path, result} -> ingest_result(by_path, path, result, policy, config) end)
      |> Enum.count(&(&1 == :linked))

    latest = Library.get_import_run(run.id)

    {:ok, updated} =
      Library.update_import_run(latest, %{
        files_matched: latest.files_matched + length(results),
        files_linked: latest.files_linked + linked
      })

    broadcast(updated)
  end

  defp ingest_result(by_path, path, result, policy, config) do
    file_id = Map.fetch!(by_path, path)
    media_file = Library.get_media_file!(file_id)

    match =
      case result do
        {:ok, match} -> match
        {:error, _reason} -> nil
      end

    case FileIngest.ingest(media_file, match, policy: policy, config: config) do
      {:linked, _item} -> :linked
      _ -> :matched
    end
  end

  # Review mode caches candidates and links nothing new from the relay, so the
  # human decides. Unattended mode links anything confident enough and leaves
  # the rest as a candidate.
  defp policy_for(:review), do: :local_only
  defp policy_for(:unattended), do: :create_items

  defp note_current_file(run, path) do
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      progress_topic(run.id),
      {:import_run_current_file, Path.basename(path)}
    )
  end

  ## Crash recovery

  # Every state Oban can hold a job in where it may still run. `:scheduled` is
  # included beyond the obvious three: a job that snoozed sits there, and
  # reconciling it would be a false positive with a real coordinator about to
  # pick the run back up.
  @live_job_states ~w(executing available retryable scheduled)

  @interrupted_error "This import was interrupted, most likely by a restart while it was running. Everything it had already added was kept. Start it again to carry on from where it stopped."

  @doc """
  Releases runs that were in flight when the node went away.

  Nothing but this coordinator ever moves a run out of `:running` or
  `:stopping`, and a partial unique index refuses a second run while either is
  present. A container restart mid-import therefore used to leave the row
  active forever: the panel showed a spinner with no worker behind it, Start
  was refused for that path, and pressing Stop made it worse by writing
  `:stopping`, which is also active. Recovery meant hand-editing the database.

  Imports run for hours and Oban's default `shutdown_grace_period` is 15
  seconds, so even a graceful `docker restart` orphans the job. This is
  routine, not an edge case.

  A run is only reconciled when no Oban job for it is in a state that could
  still execute, so this is safe to call while healthy runs are in flight.
  Returns the number of rows it changed.
  """
  @spec reconcile_interrupted_runs() :: {:ok, non_neg_integer()}
  def reconcile_interrupted_runs do
    live = live_run_ids()

    count =
      Library.list_active_import_runs()
      |> Enum.reject(&MapSet.member?(live, &1.id))
      |> Enum.count(&reconcile_run/1)

    if count > 0 do
      Logger.warning("Released import runs left in flight by an interrupted node", count: count)
    end

    {:ok, count}
  rescue
    error ->
      # Boot-time work must never take the application down with it.
      Logger.error("Could not reconcile interrupted import runs: #{inspect(error)}")
      {:ok, 0}
  end

  defp reconcile_run(run) do
    case Library.update_import_run(run, %{
           status: reconciled_status(run.status),
           phase: :finished,
           current_file: nil,
           error: @interrupted_error
         }) do
      {:ok, updated} ->
        broadcast(updated)
        true

      {:error, changeset} ->
        Logger.error("Could not release an interrupted import run",
          import_run_id: run.id,
          errors: inspect(changeset.errors)
        )

        false
    end
  end

  # A run that was already draining is reported as stopped, not failed: the
  # user asked for it to end and it did, just not cleanly.
  defp reconciled_status(:stopping), do: :stopped
  defp reconciled_status(_running), do: :failed

  # Read back in Elixir rather than filtered in SQL: pulling a value out of a
  # JSON column is not portable between SQLite and PostgreSQL, and the worker
  # plus state filter already narrows this to a handful of rows.
  defp live_run_ids do
    Oban.Job
    |> where([j], j.worker == ^inspect(__MODULE__) and j.state in ^@live_job_states)
    |> select([j], j.args)
    |> Repo.all()
    |> Enum.flat_map(fn
      %{"import_run_id" => id} when is_binary(id) -> [id]
      _ -> []
    end)
    |> MapSet.new()
  end

  ## Progress

  defp broadcast(%ImportRun{} = run) do
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      progress_topic(run.id),
      {:import_run_progress, run}
    )
  end
end
