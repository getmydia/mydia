defmodule Mydia.Jobs.ImportRun do
  @moduledoc """
  Coordinates one user-started import of a library path.

  Two phases. Phase 1 walks the tree and upserts a durable
  `Mydia.Library.ImportCandidate` row (see `Mydia.ImportCandidates`) for every
  path found, in transactions of 100. It does no HTTP, so it is fast, and once
  it has run every file on disk is durably recorded, path-keyed, and not yet
  owned by anything. Phase 2 matches the outstanding candidates against the
  metadata provider in chunks, caching a match on each candidate and, in
  unattended mode, promoting the confident ones into owned `media_files` via
  `Library.CandidatePromotion`.

  Stopping is cooperative. Stop writes `:stopping` to the run row; the
  coordinator re-reads that row between chunks and drains. Nothing is rolled
  back, because every unit of work was committed as it completed.

  There is no resume cursor. A later run rediscovers the outstanding work by
  querying for it: phase 1 skips paths that already own a `media_file` (active
  or trashed), and phase 2 (`Mydia.ImportCandidates.outstanding/3`) skips
  candidates that already carry a provider match, a dismissal, or an
  unexpired retry backoff. The database is the cursor.

  Phase 2's walk (`match_loop/5`) is a one-way keyset scan over `id`, so it
  always terminates on its own -- each chunk advances the cursor past
  whatever it just processed, and the table is finite -- regardless of
  whether every candidate in a chunk actually left the outstanding set.
  Reaching the end of the walk is therefore not the same as the phase having
  succeeded: `Library.FileIngest`'s progress contract (documented on that
  module) says every candidate must leave the outstanding set, and
  `verify_match_phase_complete/2` is what actually checks that, once the walk
  is done, failing the run rather than reporting success over candidates the
  walk quietly passed by.

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

  alias Mydia.ImportCandidates
  alias Mydia.Library

  alias Mydia.Library.{
    BatchMatcher,
    FileIngest,
    ImportCandidate,
    ImportRun,
    MetadataMatcher,
    PathAnchor,
    ReleaseParser,
    SampleDetector,
    Scanner
  }

  alias Mydia.Metadata
  alias Mydia.{Repo, Settings}

  @scan_batch_size 100
  @match_chunk_size 50

  # A run in one of these has had its verdict recorded and must never be
  # executed again. Mirrors the complement of `ImportRun.active_statuses/0`.
  @terminal_statuses ~w(done failed stopped)a

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

      # Defence in depth against a job that outlived its run's verdict. Boot
      # reconciliation retires the jobs of every run it releases, so this
      # should not be reachable, but the collision it guards against is not
      # hypothetical: `Mydia.Jobs.reset_stale_executing_jobs/1` re-queues any
      # job that has been `executing` for over an hour, and an import that ran
      # for hours before a crash is exactly that. Executing phases against a
      # terminal run would finish it at `:done` carrying somebody else's error
      # text, and would do it alongside whatever run the user started after
      # being told the first one failed.
      %ImportRun{status: status} = stale when status in @terminal_statuses ->
        Logger.warning("Refusing to execute an import run that already finished",
          import_run_id: run_id,
          status: status,
          attempt: job.attempt
        )

        broadcast(stale)
        :ok

      run ->
        execute(run, job)
    end
  end

  defp execute(run, job) do
    try do
      with :ok <- run_scan_phase(run),
           :ok <- run_match_phase(Library.get_import_run(run.id)) do
        finish(run, :done)
      else
        :stopped ->
          finish(run, :stopped)

        {:error, reason} ->
          fail(run, reason, job)
      end
    rescue
      # A crash that escapes the phases above still has to take the run to a
      # terminal state. Without this, an exception (for example
      # `Ecto.MultipleResultsError` on a duplicate row) makes Oban discard the
      # job after its retries while the run row stays `:running` forever: Start
      # is refused, Stop only writes `:stopping` (also active), and the panel
      # spins with no worker behind it. `fail/3` writes `:failed` on the final
      # attempt and keeps the run active otherwise, matching the returned-error
      # path exactly.
      error ->
        fail(run, error, job)
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
        current_file: nil,
        # The run reached its own end, so whatever was in `error` is not the
        # outcome. Leaving it would put a stale sentence under a green
        # "Import finished" in the outcome panel.
        error: nil
      })

    broadcast(updated)
    :ok
  end

  ## Phase 1: scan

  @doc """
  Walks the library path and upserts a durable `ImportCandidate` row per
  discovered path not already owned by a `media_file`.

  Returns `:ok` when the whole tree was scanned, or `:stopped` if a stop was
  requested partway through. A partial scan is valid state, not an error.

  Refuses a library path whose type is not in
  `Mydia.Library.ImportRun.importable_types/0`. The start form already filters
  those out, but this is the layer that a stale bookmark or a crafted event
  cannot walk around.

  That list currently names every value of `LibraryPath`'s type enum, so the
  guard turns nothing away today. It is kept because nothing downstream would
  catch a new type: neither `ImportCandidates.outstanding/3` nor
  `MediaFile.library_type_compatible?/3` (which falls through to `true` for
  any type it has no clause for) filters by library type. Adding a library
  type whose files are not movies or episodes has to come here first, or an
  unattended run will send them to the relay and link whatever comes back.

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
        Enum.count(batch, &upsert_candidate_for_file(&1, library_path))
      end)

    current_run = Library.get_import_run(run.id)

    {:ok, updated} =
      Library.update_import_run(current_run, %{
        files_discovered: current_run.files_discovered + inserted
      })

    broadcast(updated)
  end

  # Returns whether this path was newly discovered (had no candidate before),
  # which is what `insert_batch/3` counts toward `files_discovered`. A path
  # already owned by a live or trashed `media_file` is skipped entirely: no
  # candidate is written for it, matching the invariant that a `media_file`
  # can never be parentless (Task 1's `media_files` CHECK) and never was
  # meant to be revisited by a user-started import once something else
  # already owns it.
  defp upsert_candidate_for_file(file_info, library_path) do
    relative_path = Path.relative_to(file_info.path, library_path.path)

    if owned_path?(library_path.id, relative_path) do
      false
    else
      existing = ImportCandidates.get_by_path(library_path.id, relative_path)
      attrs = candidate_scan_attrs(file_info, library_path, relative_path, existing)

      case ImportCandidates.upsert(attrs) do
        {:ok, _candidate} ->
          is_nil(existing)

        {:error, changeset} ->
          Logger.warning("Could not upsert an import candidate during a scan",
            library_path_id: library_path.id,
            relative_path: relative_path,
            errors: inspect(changeset.errors)
          )

          false
      end
    end
  end

  # Deliberately `list_media_files_by_relative_path/3` rather than
  # `get_media_file_by_relative_path/3`: the latter raises
  # `Ecto.MultipleResultsError` on a duplicate row for one path, exactly the
  # data anomaly (two builds of the scanner, or a scanner racing this
  # coordinator) that stranded a run before `list_media_files_by_relative_path/3`
  # was written for this same "does it already exist" check. Any row at all --
  # active or trashed -- means the path is owned and phase 1 has nothing to do
  # with it.
  defp owned_path?(library_path_id, relative_path) do
    library_path_id
    |> Library.list_media_files_by_relative_path(relative_path, include_trashed: true)
    |> Enum.any?()
  end

  # `size`/`mtime`/`parsed_info`/`media_type` are refreshed on every scan --
  # they are derived from the file and the path alone, never from a match, so
  # overwriting them is always safe and keeps them current if the file on disk
  # changed. `discovered_at` is the one exception that is NOT refreshed: it is
  # first-seen time, so an existing candidate's is carried forward.
  #
  # `dismissed_at` never appears in these attrs, in either branch: leaving it
  # out of the params `ImportCandidate.changeset/2` casts is what preserves a
  # human's dismissal across a rescan (`ImportCandidates.upsert/1`'s own
  # contract). The match/retry fields (`provider_type`, `provider_id`,
  # `title`, `year`, `confidence`, `attempts`, `last_error`, `next_retry_at`)
  # are preserved the same way -- left out of the attrs -- unless the file's
  # size or mtime actually changed on disk, in which case they are explicitly
  # cleared: a match cached against the old bytes is not trustworthy evidence
  # about the new ones, and phase 2 has to re-earn it.
  defp candidate_scan_attrs(file_info, library_path, relative_path, existing) do
    mtime = DateTime.truncate(file_info.modified_at, :second)
    parsed = ReleaseParser.parse_with_path(file_info.path)
    anchor = PathAnchor.anchor_for(file_info.path, library_path.path)

    base = %{
      library_path_id: library_path.id,
      relative_path: relative_path,
      anchor_key: anchor.cluster_key,
      size: file_info.size,
      mtime: mtime,
      media_type: to_string(parsed.type),
      parsed_info: scan_parsed_info(parsed),
      discovered_at: existing_discovered_at(existing)
    }

    if existing && content_changed?(existing, file_info.size, mtime) do
      Map.merge(base, %{
        provider_type: nil,
        provider_id: nil,
        title: nil,
        year: nil,
        confidence: nil,
        attempts: 0,
        last_error: nil,
        next_retry_at: nil
      })
    else
      base
    end
  end

  defp existing_discovered_at(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)
  defp existing_discovered_at(existing), do: existing.discovered_at

  defp content_changed?(existing, size, mtime) do
    existing.size != size or mtime_differs?(existing.mtime, mtime)
  end

  # A missing mtime on either side (a candidate written by a path that never
  # set it, such as `ImportCandidates.demote_episode_files/1`) means there is
  # nothing to compare against, not proof that the file changed -- treating it
  # as a change would clear a demoted candidate's deliberately preserved
  # provider identity the moment a later scan revisits its path.
  defp mtime_differs?(nil, _mtime), do: false
  defp mtime_differs?(_mtime, nil), do: false
  defp mtime_differs?(a, b), do: DateTime.compare(a, b) != :eq

  defp scan_parsed_info(parsed) do
    %{
      "type" => to_string(parsed.type),
      "season" => parsed.season,
      "episodes" => parsed.episodes || [],
      "is_sample" => parsed.is_sample || false,
      "is_trailer" => parsed.is_trailer || false,
      "is_extra" => parsed.is_extra || false
    }
  end

  ## Phase 2: match

  @doc """
  Matches outstanding candidates in chunks, caching a match on each.

  In `:unattended` mode a match at or above the confidence threshold is
  promoted into owned media immediately. In `:review` mode nothing is
  promoted from an external provider match; the candidate stays for a human
  to decide.

  Returns `:ok` when no outstanding candidates remain, or `:stopped` if a stop
  was requested. Between chunks the run row is re-read, which is the only
  place a stop can take effect.

  ## Options

    * `:config` - metadata relay config, defaults to `Metadata.default_relay_config/0`.
      Lets a test point relay traffic at a local Bypass server without
      mutating the global `METADATA_RELAY_URL` env var (which would race any
      concurrently running async test that also resolves the default config).
    * `:matcher` - a `Mydia.Library.Matcher` implementation, defaults to
      `MetadataMatcher`. Same seam `BatchMatcher.match_paths/2` already takes;
      exposed here too so a test can drive `FileIngest`'s decision (promote,
      candidate, or a genuine write failure) directly, without needing a
      Bypass payload shaped to provoke it.
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
    matcher = Keyword.get(opts, :matcher, MetadataMatcher)
    after_chunk = Keyword.get(opts, :after_chunk, fn -> :ok end)

    {:ok, _} = Library.update_import_run(run, %{phase: :matching})

    case match_loop(run, library_path, config, matcher, after_chunk) do
      :ok -> verify_match_phase_complete(run, library_path)
      other -> other
    end
  end

  defp match_loop(
         run,
         library_path,
         config,
         matcher,
         after_chunk,
         after_id \\ nil,
         broadcast_state \\ initial_broadcast_state()
       ) do
    if Library.import_run_stopping?(run.id) do
      :stopped
    else
      case ImportCandidates.outstanding(library_path.id, @match_chunk_size, after: after_id) do
        [] ->
          :ok

        chunk ->
          broadcast_state =
            process_match_chunk(chunk, run, library_path, config, matcher, broadcast_state)

          after_chunk.()
          last_id = chunk |> List.last() |> Map.fetch!(:id)
          match_loop(run, library_path, config, matcher, after_chunk, last_id, broadcast_state)
      end
    end
  end

  # The keyset walk above can only prove it saw no outstanding candidate above
  # its cursor; it cannot prove none remain below it. A `FileIngest` bug that
  # leaves a candidate with no match, no retry timestamp, no dismissal, and no
  # promotion (breaking the progress contract documented on that module) keeps
  # whatever `id` it already had, so once the walk's cursor passes it, the
  # walk never selects that candidate again and still reports the phase done.
  # This is the real backstop for that contract now. It is strictly better
  # than a per-chunk equality check: that guard only fires once the stuck rows
  # happen to be the entire remaining window, in effect only once they sit at
  # the head of what was left to scan, while this catches them wherever they
  # are.
  #
  # Deliberately re-runs `ImportCandidates.outstanding/3`'s own predicate
  # (via `count_outstanding/1`) rather than a stricter "no candidate row at
  # all" check: under this model every discovered path already IS a candidate
  # row from phase 1 onward, so there is no separate "no candidate" state left
  # to detect. A candidate whose backoff has not yet elapsed is healthy,
  # expected steady state -- excluded from the count below the same way it is
  # excluded from the walk -- and only a candidate the walk passed without
  # leaving in ANY resolved state (matched, freshly retried, dismissed, or
  # promoted away entirely) reappears here.
  defp verify_match_phase_complete(run, library_path) do
    case ImportCandidates.count_outstanding(library_path.id) do
      0 ->
        :ok

      count ->
        sample_ids =
          library_path.id
          |> ImportCandidates.outstanding(5)
          |> Enum.map(& &1.id)

        # `count:`/`candidate_ids:` (a comma-joined string, not a raw list)
        # match `Library.drop_unresolvable_paths/1`'s convention for the same
        # reason: neither key is in `config :logger, :default_formatter`'s
        # metadata allowlist under those other names, so anything else here
        # renders nowhere -- silently, the same failure mode this whole check
        # exists to stop happening one layer up.
        Logger.error("Import run finished matching but candidates are still outstanding",
          import_run_id: run.id,
          library_path_id: library_path.id,
          count: count,
          candidate_ids: Enum.map_join(sample_ids, ",", & &1)
        )

        {:error,
         {:candidates_outstanding,
          "The import finished but #{count} file(s) never got a match result and are still outstanding. This is a bug, please report it."}}
    end
  end

  defp process_match_chunk(chunk, run, library_path, config, matcher, broadcast_state) do
    by_path =
      Map.new(chunk, fn candidate -> {ImportCandidate.absolute_path(candidate), candidate} end)

    policy = if run.mode == :unattended, do: :unattended, else: :review

    results =
      by_path
      |> Map.keys()
      |> BatchMatcher.match_paths(
        library_root: library_path.path,
        matcher: matcher,
        config: config,
        provider: library_path.tv_metadata_source
      )

    promoted =
      results
      |> Enum.map(fn {path, result} -> ingest_result(by_path, path, result, policy, config) end)
      |> Enum.count(&match?({:promoted, _}, &1))

    latest = Library.get_import_run(run.id)

    {:ok, updated} =
      Library.update_import_run(latest, %{
        files_matched: latest.files_matched + length(results),
        files_linked: latest.files_linked + promoted
      })

    broadcast(updated)

    # `BatchMatcher.match_paths/2` runs its groups concurrently (see its
    # moduledoc), so per-file progress can only be folded safely here, back on
    # the single-threaded match loop, after every worker has already returned.
    Enum.reduce(results, broadcast_state, fn {path, _result}, state ->
      maybe_broadcast(state, run, path)
    end)
  end

  defp ingest_result(by_path, path, result, policy, config) do
    candidate = Map.fetch!(by_path, path)

    match =
      case result do
        {:ok, match} -> match
        {:error, _reason} -> nil
      end

    FileIngest.ingest(candidate, match, policy: policy, config: config)
  end

  @broadcast_file_interval 1_000
  @broadcast_ms_interval 1_000

  defp initial_broadcast_state do
    %{since_broadcast: 0, last_broadcast_at: System.monotonic_time(:millisecond)}
  end

  # A 200k run at one broadcast per file is 200k LiveView renders, each
  # preceded by a run-row read and followed by a write. Coalescing makes
  # progress cost O(seconds) instead of O(files).
  defp maybe_broadcast(state, run, path) do
    now = System.monotonic_time(:millisecond)

    if state.since_broadcast >= @broadcast_file_interval or
         now - state.last_broadcast_at >= @broadcast_ms_interval do
      note_current_file(run, path)
      %{state | since_broadcast: 0, last_broadcast_at: now}
    else
      %{state | since_broadcast: state.since_broadcast + 1}
    end
  end

  defp note_current_file(run, path) do
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      progress_topic(run.id),
      {:import_run_current_file, Path.basename(path)}
    )
  end

  ## Crash recovery

  # States where a job is queued and will run again on its own. `scheduled` is
  # included beyond the obvious two: a snoozed job sits there, and reconciling
  # it would be a false positive with a real coordinator about to pick the run
  # back up.
  @queued_job_states ~w(available retryable scheduled)

  # `executing` is deliberately NOT in the list above, because it is the state
  # this whole function exists for. Without `Oban.Plugins.Lifeline` (see the
  # moduledoc for why it cannot be used here), nothing ever moves a job out of
  # `executing` when the node dies mid-run: `Engine.shutdown/2` only sets
  # `paused: true`. So a lingering `executing` row is the normal shape of the
  # crash being recovered from, and treating it as "still live" made this
  # function a no-op for its own purpose.
  #
  # It cannot be blanket-ignored either, since a healthy job is `executing`
  # too. The discriminator is ordering, not row contents:
  # `Mydia.Jobs.ImportRunReconciler` runs before this node's Oban child starts,
  # so no local queue can have claimed anything yet. A row attempted by THIS
  # node therefore has to be a leftover. A row attempted by a different node is
  # somebody else's live job and is left alone.
  @executing_state "executing"

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

  Called from `Mydia.Jobs.ImportRunReconciler`, which is positioned in the
  supervision tree before this node's Oban child so that a lingering
  `executing` job row is unambiguous. See that module and `live_job?/3`.
  Returns the number of rows it changed.
  """
  @spec reconcile_interrupted_runs() :: {:ok, non_neg_integer()}
  def reconcile_interrupted_runs do
    jobs = unfinished_jobs()
    live = live_run_ids(jobs)
    jobs_by_run = Enum.group_by(jobs, & &1.run_id, & &1.id)

    count =
      Library.list_active_import_runs()
      |> Enum.reject(&MapSet.member?(live, &1.id))
      |> Enum.count(&reconcile_run(&1, Map.get(jobs_by_run, &1.id, [])))

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

  defp reconcile_run(run, job_ids) do
    case Library.update_import_run(run, %{
           status: reconciled_status(run.status),
           phase: :finished,
           current_file: nil,
           error: @interrupted_error
         }) do
      {:ok, updated} ->
        retire_jobs(run, job_ids)
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

  # Retiring the job is not bookkeeping, it is what makes the terminal status
  # above stick.
  #
  # `Mydia.Application` calls `Mydia.Jobs.reset_stale_executing_jobs/1` later in
  # the same boot, which flips ANY job still `executing` with an `attempted_at`
  # over an hour old back to `available`. An import that ran for hours before
  # the crash is exactly that job. Without this, the run row said `:failed`
  # while Oban happily re-queued and re-ran the very coordinator this function
  # just declared dead, against a terminal run, finishing at `:done` with the
  # interruption text still attached. Worse, `:failed` is not active, so Start
  # was enabled and the user following this function's own error message could
  # put a second coordinator on the same library path: the partial unique index
  # guards active `import_runs` rows, not Oban jobs.
  #
  # Written with `Repo.update_all` rather than `Oban.cancel_all_jobs/1` because
  # no Oban instance is running yet at this point in boot, which is the same
  # ordering that makes an `executing` row readable as stale in the first
  # place. `cancelled` (not `discarded`) because this is a deliberate
  # retirement, and the Pruner cleans it up on the same schedule either way.
  defp retire_jobs(_run, []), do: :ok

  defp retire_jobs(run, job_ids) do
    {count, _} =
      Oban.Job
      |> where([j], j.id in ^job_ids)
      |> Repo.update_all(set: [state: "cancelled", cancelled_at: DateTime.utc_now()])

    Logger.warning("Retired the Oban jobs of an interrupted import run",
      import_run_id: run.id,
      jobs: count
    )

    :ok
  end

  # A run that was already draining is reported as stopped, not failed: the
  # user asked for it to end and it did, just not cleanly.
  defp reconciled_status(:stopping), do: :stopped
  defp reconciled_status(_running), do: :failed

  # Every coordinator job that has not reached a terminal Oban state, projected
  # to just what the two callers below need. Read back in Elixir rather than
  # filtered in SQL: pulling a value out of a JSON column is not portable
  # between SQLite and PostgreSQL, and the worker plus state filter already
  # narrows this to a handful of rows.
  defp unfinished_jobs do
    states = [@executing_state | @queued_job_states]

    Oban.Job
    |> where([j], j.worker == ^inspect(__MODULE__) and j.state in ^states)
    |> select([j], {j.id, j.state, j.attempted_by, j.args})
    |> Repo.all()
    |> Enum.flat_map(fn
      {id, state, attempted_by, %{"import_run_id" => run_id}} when is_binary(run_id) ->
        [%{id: id, state: state, attempted_by: attempted_by, run_id: run_id}]

      _ ->
        []
    end)
  end

  defp live_run_ids(jobs) do
    this_node = Oban.Config.node_name()

    jobs
    |> Enum.filter(&live_job?(&1.state, &1.attempted_by, this_node))
    |> MapSet.new(& &1.run_id)
  end

  # `attempted_by` is `[node, uuid]` on the Basic engine and `[node]` on Lite,
  # so only the head is portable. That is enough here: this runs before any
  # local queue exists, so the only node whose `executing` row can be trusted
  # as live is one that is not us.
  defp live_job?(@executing_state, [node | _], this_node), do: node != this_node
  defp live_job?(@executing_state, _attempted_by, _this_node), do: false
  defp live_job?(_queued, _attempted_by, _this_node), do: true

  ## Progress

  defp broadcast(%ImportRun{} = run) do
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      progress_topic(run.id),
      {:import_run_progress, run}
    )
  end
end
