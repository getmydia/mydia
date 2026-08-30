defmodule Mydia.Jobs.LibraryScanner do
  @moduledoc """
  Background job for scanning the media library.

  This job:
  - Scans configured library paths for media files
  - Detects new, modified, and deleted files
  - Updates the database with file information
  - Tracks scan status and errors

  Known-file maintenance -- detecting modified/deleted owned files, restoring
  a file that reappears at a previously-trashed path, adopting/reaping
  sidecar subtitles, and reaping `ImportCandidate` rows whose paths
  disappeared -- always runs, regardless of a library path's `auto_import`
  setting. Discovery of paths this library does not yet own only runs when
  `auto_import` is true: see `scan_library_path/2` and
  `discover_unknown_paths/3`. With `auto_import: false`, an unrecognized
  path is left alone entirely -- no candidate, no parse, no relay call --
  for a human to pick up through the import inbox.

  Scans enqueued automatically (the interval scheduler and the boot-time health
  check) carry a random `schedule_in` delay of up to 30 minutes, which spreads
  load across self-hosted instances hitting the metadata relay. See
  `jitter_seconds/0`. Manual triggers insert with no delay and run immediately.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3,
    unique: [
      period: :infinity,
      states: [:available, :scheduled, :executing, :retryable, :suspended],
      keys: [:library_path_id, :library_type]
    ]

  require Logger
  alias Mydia.{Library, Settings, Repo, Metadata}
  alias Mydia.ImportCandidates
  alias Mydia.Subtitles.Sidecars

  # Upper bound of the insert-time jitter applied to automatic scans.
  @max_startup_delay_ms 30 * 60 * 1000

  # Page size for draining ImportCandidates.outstanding/3 during discovery.
  @discovery_chunk_size 50

  alias Mydia.Library.{
    BatchMatcher,
    FileIngest,
    ImportCandidate,
    MetadataMatcher,
    PathAnchor,
    ScanSummary
  }

  alias Mydia.Settings.LibraryPath

  alias Mydia.Library.ReleaseParser, as: FileParser

  defmodule Args do
    @moduledoc false
    defstruct [:library_path_id, :library_type]

    @type t :: %__MODULE__{
            library_path_id: String.t() | nil,
            library_type: String.t() | nil
          }

    def parse(raw) do
      %__MODULE__{
        library_path_id: Map.get(raw, "library_path_id"),
        library_type: Map.get(raw, "library_type")
      }
    end
  end

  @doc """
  Random delay for automatically enqueued scans: 1 second to 30 minutes,
  returned in seconds.

  Spreads metadata-relay load across self-hosted instances whose crons and
  restarts cluster on the same moments. Applied via Oban `schedule_in` so the
  job waits in the `:scheduled` state instead of occupying a `:media` queue slot.
  """
  @spec jitter_seconds() :: pos_integer()
  def jitter_seconds, do: :rand.uniform(div(@max_startup_delay_ms, 1000))

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: raw_args}) do
    args = Args.parse(raw_args)
    library_path_id = args.library_path_id
    library_type = args.library_type

    start_time = System.monotonic_time(:millisecond)

    result =
      cond do
        library_path_id != nil ->
          scan_single_library(library_path_id)

        library_type != nil ->
          scan_libraries_by_type(String.to_existing_atom(library_type))

        true ->
          scan_all_libraries()
      end

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      :ok ->
        Logger.info("Library scan job completed",
          duration_ms: duration,
          library_path_id: library_path_id,
          library_type: library_type
        )

        :ok

      {:error, reason} ->
        Logger.error("Library scan job failed",
          error: inspect(reason),
          duration_ms: duration,
          library_path_id: library_path_id,
          library_type: library_type
        )

        {:error, reason}
    end
  end

  ## Private Functions

  defp scan_all_libraries do
    Logger.info("Starting scan of all monitored library paths")

    library_paths = Settings.list_library_paths()
    monitored_paths = Enum.filter(library_paths, & &1.monitored)

    Logger.info("Found #{length(monitored_paths)} monitored library paths")

    results =
      Enum.map(monitored_paths, fn library_path ->
        scan_library_path(library_path)
      end)

    successful = Enum.count(results, &match?({:ok, _}, &1))
    failed = Enum.count(results, &match?({:error, _}, &1))

    Logger.info("Library scan completed",
      total: length(results),
      successful: successful,
      failed: failed
    )

    :ok
  end

  defp scan_libraries_by_type(library_type) do
    Logger.info("Starting scan of library paths by type", library_type: library_type)

    library_paths = Settings.list_library_paths()

    # For manual scans by type, include all libraries of that type (not just monitored)
    # This allows users to trigger re-scans even for unmonitored libraries
    paths_of_type = Enum.filter(library_paths, &(&1.type == library_type))

    Logger.info("Found #{length(paths_of_type)} #{library_type} library paths")

    results =
      Enum.map(paths_of_type, fn library_path ->
        scan_library_path(library_path)
      end)

    successful = Enum.count(results, &match?({:ok, _}, &1))
    failed = Enum.count(results, &match?({:error, _}, &1))

    Logger.info("Library scan by type completed",
      library_type: library_type,
      total: length(results),
      successful: successful,
      failed: failed
    )

    :ok
  end

  defp scan_single_library(library_path_id) do
    Logger.info("Starting scan of library path", library_path_id: library_path_id)

    library_path = Settings.get_library_path!(library_path_id)

    case scan_library_path(library_path) do
      {:ok, %ScanSummary{} = summary} ->
        Logger.info("Library scan completed successfully",
          library_path_id: library_path_id,
          new_files: summary.new_files,
          modified_files: summary.modified_files,
          deleted_files: summary.deleted_files
        )

        :ok

      {:error, reason} ->
        Logger.error("Library scan failed",
          library_path_id: library_path_id,
          reason: reason
        )

        {:error, reason}
    end
  end

  @doc false
  # Public so a test can inject a deterministic `:matcher` (and other
  # discovery options) into a real scan without going through Oban's
  # `perform/1` args map, which has no room for one. Real scans never pass
  # opts; `opts` flows unchanged into `discover_unknown_paths/3`.
  @spec scan_library_path(LibraryPath.t(), keyword()) :: {:ok, ScanSummary.t()} | {:error, term()}
  def scan_library_path(library_path, opts \\ []) do
    Logger.debug("Scanning library path",
      id: library_path.id,
      path: library_path.path,
      type: library_path.type
    )

    # Broadcast scan started
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "library_scanner",
      {:library_scan_started, %{library_path_id: library_path.id, type: library_path.type}}
    )

    # Mark scan as in progress (skip for runtime paths)
    if updatable_library_path?(library_path) do
      {:ok, _} =
        Settings.update_library_path(library_path, %{
          last_scan_status: :in_progress,
          last_scan_error: nil
        })
    end

    progress_callback = fn count ->
      Logger.debug("Scan progress", library_path_id: library_path.id, files_scanned: count)
    end

    extensions = Library.Scanner.extensions_for_library_type(library_path.type)

    # Perform scan and handle errors gracefully
    with {:ok, scan_result} <-
           Library.Scanner.scan(library_path.path,
             progress_callback: progress_callback,
             video_extensions: extensions
           ) do
      summary = summarize(process_scan_result(library_path, scan_result, opts))

      if reconcile_sidecars?(summary) do
        reconcile_sidecars(library_path)
      end

      summary
    else
      {:error, :not_found} ->
        handle_scan_error(library_path, "Library path does not exist: #{library_path.path}")

      {:error, :not_directory} ->
        handle_scan_error(library_path, "Path is not a directory: #{library_path.path}")

      {:error, :permission_denied} ->
        handle_scan_error(
          library_path,
          "Permission denied when accessing path: #{library_path.path}"
        )

      {:error, reason} ->
        handle_scan_error(library_path, "Scan failed: #{inspect(reason)}")
    end
  end

  defp handle_scan_error(library_path, error_message) do
    Logger.error("Library scan error",
      library_path_id: library_path.id,
      error: error_message
    )

    # Update library path with error status (skip for runtime paths)
    if updatable_library_path?(library_path) do
      {:ok, _} =
        Settings.update_library_path(library_path, %{
          last_scan_at: DateTime.utc_now(),
          last_scan_status: :failed,
          last_scan_error: error_message
        })
    end

    # Broadcast scan failed
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "library_scanner",
      {:library_scan_failed,
       %{library_path_id: library_path.id, type: library_path.type, error: error_message}}
    )

    {:error, error_message}
  end

  # process_scan_result/3 returns its counts under a :changes key alongside
  # discovery bookkeeping. Convert them to a ScanSummary so callers read one
  # shape and cannot reach into the processor's internal shape by accident.
  defp summarize({:ok, %{changes: changes} = details}) do
    {:ok,
     %ScanSummary{
       new_files: length(changes.new_files),
       modified_files: length(changes.modified_files),
       deleted_files: length(changes.deleted_files),
       auto_linked: Map.get(details, :auto_promoted, 0),
       details: details
     }}
  end

  # Errors from handle_scan_error/2 pass through unchanged.
  defp summarize(other), do: other

  @doc false
  # Public only so this guard can be unit-tested directly. `summary` reads
  # `{:ok, _}` when Library.Scanner.scan/2 succeeded and process_scan_result/3
  # ran to completion, and `{:error, _}` both when the filesystem scan itself
  # failed (the `with` block's `else` clauses handle that and never reach the
  # call site this guards) and when process_scan_result/3 raised internally
  # and its own rescue converted that into handle_scan_error/2's error tuple
  # rather than letting the exception escape. That second case is what this
  # guard exists for: without it, reconciliation would run against a scan the
  # job reports as failed.
  @spec reconcile_sidecars?({:ok, ScanSummary.t()} | {:error, term()}) :: boolean()
  def reconcile_sidecars?(summary), do: match?({:ok, _}, summary)

  # Sidecar adoption runs after media files are upserted, because it needs
  # their rows to attach to. A failure here never fails the scan: the video
  # files are indexed either way, and a missing subtitle row is recoverable
  # by rescanning. The return value is not used by the caller; this always
  # reports :ok so a call site never has to distinguish "reconciled" from
  # "skipped after logging".
  @spec reconcile_sidecars(Settings.LibraryPath.t()) :: :ok
  defp reconcile_sidecars(library_path) do
    media_files =
      Library.list_media_files(library_path_id: library_path.id, preload: [:library_path])

    tally = Sidecars.reconcile_all(media_files)

    if tally.adopted > 0 or tally.reaped > 0 do
      Logger.info("Sidecar subtitles reconciled",
        library_path_id: library_path.id,
        adopted: tally.adopted,
        reaped: tally.reaped,
        skipped: tally.skipped
      )
    end

    :ok
  rescue
    error ->
      Logger.warning("Sidecar reconciliation failed",
        library_path_id: library_path.id,
        error: Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  # The auto-import boundary. Known-file maintenance (modification,
  # deletion/trashing, trashed-path restoration) and candidate reaping run
  # unconditionally, in both modes, before anything below ever looks at
  # `library_path.auto_import`. Only discovery of paths this library does
  # not yet own is gated: with auto_import false, `unknown` is computed and
  # then simply never handed to discover_unknown_paths/3, so no candidate is
  # written and no parser, matcher, or relay call ever runs for it.
  defp process_scan_result(library_path, scan_result, opts) do
    existing_files = Library.list_media_files(library_path_id: library_path.id)
    changes = Library.Scanner.detect_changes(scan_result, existing_files, library_path)

    process_modified_files(changes.modified_files, library_path)
    process_deleted_files(changes.deleted_files)

    {restored_count, unknown} = partition_and_restore(changes.new_files, library_path)

    on_disk_paths = Enum.map(scan_result.files, &Path.relative_to(&1.path, library_path.path))
    {reaped_candidates, _} = ImportCandidates.delete_missing(library_path.id, on_disk_paths)

    discovery =
      if library_path.auto_import do
        discover_unknown_paths(library_path, unknown, opts)
      else
        %{candidates: 0, auto_promoted: 0}
      end

    # Update library path with success status (skip for runtime paths)
    if updatable_library_path?(library_path) do
      {:ok, _} =
        Settings.update_library_path(library_path, %{
          last_scan_at: DateTime.utc_now(),
          last_scan_status: :success,
          last_scan_error: nil
        })
    end

    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "library_scanner",
      {:library_scan_completed,
       %{
         library_path_id: library_path.id,
         type: library_path.type,
         new_files: length(changes.new_files),
         modified_files: length(changes.modified_files),
         deleted_files: length(changes.deleted_files),
         auto_linked: discovery.auto_promoted
       }}
    )

    {:ok,
     %{
       changes: changes,
       discovery: discovery,
       auto_promoted: discovery.auto_promoted,
       restored: restored_count,
       reaped_candidates: reaped_candidates
     }}
  rescue
    error ->
      error_message = Exception.format(:error, error, __STACKTRACE__)
      Logger.error("Library scan raised exception", error: error_message)
      handle_scan_error(library_path, error_message)
  end

  # Known-file maintenance: a file whose size or effective mtime changed
  # since it was last verified gets its stats refreshed. Runs unconditionally,
  # in both auto_import modes.
  defp process_modified_files(modified_file_infos, library_path) do
    Enum.each(modified_file_infos, fn file_info ->
      relative_path = Path.relative_to(file_info.path, library_path.path)

      case Library.get_media_file_by_relative_path(library_path.id, relative_path) do
        nil ->
          Logger.warning("Modified file not found in database",
            path: file_info.path,
            relative_path: relative_path
          )

        media_file ->
          {:ok, _} =
            Library.update_media_file_scan(media_file, %{
              size: file_info.size,
              verified_at: DateTime.utc_now()
            })

          Logger.debug("Updated media file", path: file_info.path)
      end
    end)

    :ok
  end

  # Known-file maintenance: an owned file no longer found on disk is trashed,
  # not deleted -- `Library.trash_media_file/1` moves the record into the
  # trashed state so it can be restored if the file reappears (see
  # partition_and_restore/2). Runs unconditionally, in both auto_import modes.
  defp process_deleted_files(deleted_media_files) do
    Enum.each(deleted_media_files, fn media_file ->
      media_file = Repo.preload(media_file, :library_path)
      absolute_path = Mydia.Library.MediaFile.absolute_path(media_file)

      # These files are missing from disk, which is the one case
      # Library.trash_media_file/1 has nothing to move, so a failure here is
      # a database problem. Log it and keep going rather than crashing the
      # whole scan over one row.
      case Library.trash_media_file(media_file) do
        {:ok, _} ->
          Logger.debug("Trashed media file record", path: absolute_path)

        {:error, reason} ->
          Logger.error("Failed to trash a media file missing from disk",
            path: absolute_path,
            media_file_id: media_file.id,
            reason: inspect(reason)
          )
      end
    end)

    :ok
  end

  # `changes.new_files` (from Library.Scanner.detect_changes/3) is every path
  # with no *active* owned media file. Some of those paths match a
  # previously-trashed media file at the exact same relative path instead --
  # that path was never unknown to this library, so restoring it is
  # known-file maintenance, not discovery, and runs the same in both
  # auto_import modes. What is left after peeling those off is genuinely
  # unknown, and is the only thing the auto_import gate in
  # process_scan_result/3 ever gets to see.
  defp partition_and_restore(new_file_infos, library_path) do
    {restored_count, unknown_acc} =
      Enum.reduce(new_file_infos, {0, []}, fn file_info, {restored_count, unknown_acc} ->
        relative_path = Path.relative_to(file_info.path, library_path.path)

        case Library.get_media_file_by_relative_path(library_path.id, relative_path,
               include_trashed: true
             ) do
          %{trashed_at: %DateTime{}} = trashed_file ->
            case Library.restore_media_file(trashed_file) do
              {:ok, _restored} ->
                Logger.info("Restored trashed media file",
                  path: file_info.path,
                  relative_path: relative_path
                )

                {restored_count + 1, unknown_acc}

              {:error, reason} ->
                Logger.error("Failed to restore trashed media file",
                  path: file_info.path,
                  relative_path: relative_path,
                  reason: inspect(reason)
                )

                {restored_count, unknown_acc}
            end

          _ ->
            {restored_count, [file_info | unknown_acc]}
        end
      end)

    {restored_count, Enum.reverse(unknown_acc)}
  end

  # Plex-mode discovery. Every unrecognized path becomes (or refreshes) a
  # durable ImportCandidate first -- local parsing only, no relay call, and
  # an existing candidate's dismissal is preserved by ImportCandidates.upsert/1
  # never touching :dismissed_at. Only then is every currently-outstanding
  # candidate for this library path -- this scan's new arrivals plus any
  # earlier candidate whose retry backoff has since elapsed -- batch-matched
  # and hand to FileIngest.ingest/3 under the :unattended policy. A confident
  # match promotes into an owned media file; anything else (low confidence,
  # no match, or a parsed extra/sample/trailer, which FileIngest always keeps
  # in review) stays a candidate.
  #
  # Never called when library_path.auto_import is false: the caller
  # (process_scan_result/3) substitutes a static %{candidates: 0,
  # auto_promoted: 0} instead, so this function -- and therefore
  # Metadata.default_relay_config/0, FileParser, BatchMatcher, and
  # MetadataMatcher -- never runs for a library that has not opted in.
  defp discover_unknown_paths(library_path, unknown_file_infos, opts) do
    Enum.each(unknown_file_infos, &upsert_discovered_candidate(&1, library_path))

    matcher = Keyword.get(opts, :matcher, MetadataMatcher)
    config = Keyword.get(opts, :config) || Metadata.default_relay_config()

    auto_promoted = match_outstanding_candidates(library_path, matcher, config)

    if unknown_file_infos != [] do
      Logger.info("Discovered unrecognized paths during scan",
        library_path_id: library_path.id,
        count: length(unknown_file_infos)
      )
    end

    %{candidates: length(unknown_file_infos), auto_promoted: auto_promoted}
  end

  defp upsert_discovered_candidate(file_info, library_path) do
    relative_path = Path.relative_to(file_info.path, library_path.path)
    existing = ImportCandidates.get_by_path(library_path.id, relative_path)
    attrs = discovered_candidate_attrs(file_info, library_path, relative_path, existing)

    case ImportCandidates.upsert(attrs) do
      {:ok, _candidate} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Could not upsert an import candidate during a scan",
          library_path_id: library_path.id,
          relative_path: relative_path,
          errors: inspect(changeset.errors)
        )

        :error
    end
  end

  # `size`/`mtime`/`parsed_info`/`media_type` are refreshed on every scan --
  # they are derived from the file and the path alone, never from a match, so
  # overwriting them is always safe and keeps them current if the file on disk
  # changed. `discovered_at` is the one exception that is NOT refreshed: it is
  # first-seen time, so an existing candidate's is carried forward.
  #
  # `dismissed_at` never appears in these attrs: leaving it out of the params
  # `ImportCandidate.changeset/2` casts is what preserves a human's dismissal
  # across a rescan (`ImportCandidates.upsert/1`'s own contract). The
  # match/retry fields are preserved the same way -- left out of the attrs --
  # unless the file's size or mtime actually changed on disk, in which case
  # they are explicitly cleared: a match cached against the old bytes is not
  # trustworthy evidence about the new ones.
  defp discovered_candidate_attrs(file_info, library_path, relative_path, existing) do
    mtime = DateTime.truncate(file_info.modified_at, :second)
    parsed = FileParser.parse_with_path(file_info.path)
    anchor = PathAnchor.anchor_for(file_info.path, library_path.path)

    base = %{
      library_path_id: library_path.id,
      relative_path: relative_path,
      anchor_key: anchor.cluster_key,
      size: file_info.size,
      mtime: mtime,
      media_type: to_string(parsed.type),
      parsed_info: discovered_candidate_parsed_info(parsed),
      discovered_at: existing_discovered_at(existing)
    }

    if existing && candidate_content_changed?(existing, file_info.size, mtime) do
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

  defp candidate_content_changed?(existing, size, mtime) do
    existing.size != size or candidate_mtime_differs?(existing.mtime, mtime)
  end

  # A missing mtime on either side means there is nothing to compare against,
  # not proof that the file changed.
  defp candidate_mtime_differs?(nil, _mtime), do: false
  defp candidate_mtime_differs?(_mtime, nil), do: false
  defp candidate_mtime_differs?(a, b), do: DateTime.compare(a, b) != :eq

  defp discovered_candidate_parsed_info(parsed) do
    %{
      "type" => to_string(parsed.type),
      "season" => parsed.season,
      "episodes" => parsed.episodes || [],
      "is_sample" => parsed.is_sample || false,
      "is_trailer" => parsed.is_trailer || false,
      "is_extra" => parsed.is_extra || false
    }
  end

  # Keyset-drains every outstanding candidate for the library path in pages
  # of @discovery_chunk_size, matching and ingesting each page before moving
  # to the next, so one scan settles as much of the backlog as it can rather
  # than leaving everything past the first page for the next scheduled run.
  defp match_outstanding_candidates(library_path, matcher, config, after_id \\ nil, promoted \\ 0) do
    case ImportCandidates.outstanding(library_path.id, @discovery_chunk_size, after: after_id) do
      [] ->
        promoted

      chunk ->
        chunk_promoted = match_and_ingest_chunk(chunk, library_path, matcher, config)
        last_id = chunk |> List.last() |> Map.fetch!(:id)

        match_outstanding_candidates(
          library_path,
          matcher,
          config,
          last_id,
          promoted + chunk_promoted
        )
    end
  end

  defp match_and_ingest_chunk(chunk, library_path, matcher, config) do
    by_path = Map.new(chunk, &{ImportCandidate.absolute_path(&1), &1})

    by_path
    |> Map.keys()
    |> BatchMatcher.match_paths(
      library_root: library_path.path,
      matcher: matcher,
      config: config,
      provider: library_path.tv_metadata_source
    )
    |> Enum.map(fn {path, result} -> ingest_discovered_match(by_path, path, result, config) end)
    |> Enum.count(&match?({:promoted, _}, &1))
  end

  defp ingest_discovered_match(by_path, path, result, config) do
    candidate = Map.fetch!(by_path, path)

    match =
      case result do
        {:ok, match} -> match
        {:error, _reason} -> nil
      end

    FileIngest.ingest(candidate, match, policy: :unattended, config: config)
  end

  # Checks if a library path can be updated in the database.
  # Runtime library paths (from environment variables) can't be updated.
  defp updatable_library_path?(%{id: id}) when is_binary(id) do
    !String.starts_with?(id, "runtime::")
  end

  defp updatable_library_path?(_), do: true
end
