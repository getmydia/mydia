defmodule Mydia.Jobs.MediaImport do
  @moduledoc """
  Background job for importing completed downloads into the media library.

  This job:
  - Imports downloaded files using hardlinks (when on same filesystem), moves, or copies
  - Organizes files according to media type (Movies/Title/ or TV/Show/Season XX/)
  - Creates media_files records with correct associations
  - Handles conflicts and errors gracefully
  - Optionally removes download from client after successful import

  ## File Operation Priority

  When importing files, the following priority is used:
  1. Hardlink (instant, no duplicate storage) - requires same filesystem
  2. Copy, so a seeding torrent keeps its file

  Sources of downloads from clients that never seed
  (`ClientRemoval.non_seeding_type?/1`) are removed once the import has been
  recorded, not at placement, so a retried import still finds them.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1000,
    # Full incomplete-state set: every normal caller (Downloads.Queue, DownloadMonitor,
    # the downloads LiveView) gets full duplicate protection, including against
    # a MediaImport job that's already :executing for the same download_id.
    # `Failure.schedule_snooze_retry/3` is the one exception — it overrides
    # `:states` at the call site to drop `:executing`, since it needs to
    # self-reinsert while its own parent job is still running.
    unique: [
      period: 600,
      keys: [:download_id],
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  require Logger
  alias Mydia.{Downloads, Media}
  alias Mydia.Accounts.Scope
  alias Mydia.Downloads.ClientRemoval
  alias Mydia.Downloads.ImportCandidates
  alias Mydia.MediaServer.Notifier, as: MediaServerNotifier
  alias Mydia.Metadata.NfoWriter
  alias Mydia.Jobs.MediaImport.{Args, Discovery, FileImport, Failure, Paths, Placement}

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"download_id" => _} = raw_args, attempt: attempt}) do
    args = Args.parse(raw_args)
    download_id = args.download_id

    Logger.info("Starting media import",
      download_id: download_id,
      attempt: attempt
    )

    case fetch_download(download_id) do
      :not_found ->
        # Self-heal: the row was deleted (by failure handling, or by the user
        # dismissing it). No work to do — mark the job done so Oban stops
        # retrying.
        Logger.info("Media import short-circuit: download row no longer exists",
          download_id: download_id
        )

        :ok

      {:ok, download} ->
        perform_with_download(download, args, attempt, raw_args)
    end
  end

  defp perform_with_download(download, args, attempt, raw_args) do
    download_id = download.id

    cond do
      not is_nil(download.removal_requested_at) ->
        # The operator asked for this download to be removed and its files may
        # be mid-delete. Mydia.Jobs.RemoveDownload owns the row now.
        Logger.info("Media import short-circuit: removal requested",
          download_id: download_id
        )

        :ok

      not is_nil(download.imported_at) ->
        # Idempotency guard: download already imported. Duplicate enqueues
        # from polling, retries, or snooze races land here harmlessly. Do
        # NOT fall into the snooze loop or re-import below.
        Logger.debug("Media import short-circuit: download already imported",
          download_id: download_id,
          imported_at: download.imported_at
        )

        :ok

      is_nil(download.completed_at) ->
        Failure.handle_incomplete_download(download, args, attempt, raw_args)

      true ->
        args = %{args | move_source: ClientRemoval.import_consumes_source?(download)}

        case import_download(download, args) do
          {:ok, result} ->
            # Success - clear any retry metadata
            Failure.clear_retry_metadata(download)
            {:ok, result}

          {:error, reason} ->
            # Failure - update retry metadata. If the failure is structurally
            # unfixable (e.g. a completed torrent contains zero importable
            # media files, or its save path has been gone for several
            # attempts), stop Oban's retry loop so the row doesn't keep
            # re-scanning for days.
            terminal? = terminal_failure?(reason, attempt)
            Failure.handle_import_failure(download, reason, attempt, terminal?: terminal?)

            if terminal? do
              {:cancel, reason}
            else
              {:error, reason}
            end
        end
    end
  end

  # Classifies failures whose state will not change by retrying.
  #
  # `:no_importable_files` fires only after a *completed* torrent has been
  # scanned and zero files matched the video-extension whitelist. Re-scanning
  # the same finished torrent will deterministically produce the same result,
  # so retrying is pointless. The common cause in production is malware
  # torrents named `*.1080p.WEB.h264-<group>.exe` — the importer correctly
  # rejects them, then they sit in the retry queue for weeks.
  #
  # Filesystem-availability errors (`:path_not_found`, `:path_not_accessible`)
  # can legitimately be transient — a remote mount blip, a torrent client
  # that hasn't finished moving files yet — so they get a small budget of
  # retries before we give up.
  defp terminal_failure?(:no_importable_files, _attempt), do: true
  # A path-mapping mismatch cannot self-heal by retrying — only an operator
  # applying a mapping resolves it — so go terminal immediately instead of
  # burning the retry budget (and flooding telemetry) across three attempts.
  defp terminal_failure?({:path_mapping_mismatch, _path}, _attempt), do: true
  defp terminal_failure?({:path_not_found, _path}, attempt) when attempt >= 3, do: true
  defp terminal_failure?({:path_not_accessible, _path}, attempt) when attempt >= 3, do: true
  # The client reported a per-download file list and none of those paths exist
  # locally. A mount blip or a client still moving files can explain it, so
  # allow a few retries; past that it is a path-mapping or client problem that
  # only an operator resolves.
  defp terminal_failure?({:scoped_files_missing, _count}, attempt) when attempt >= 3, do: true
  # The client reports its own download root as this download's save_path, so we
  # cannot tell which files belong to it. Retrying re-reads the same config and
  # gets the same answer; only an operator changing the client's layout (or
  # adding a path mapping) fixes it.
  defp terminal_failure?({:save_path_is_download_root, _path}, _attempt), do: true
  # The download names a client that is no longer in the configuration — the
  # operator retired or renamed it. Every retry re-reads the same config, so
  # with max_attempts: 1000 the row retried effectively forever, and because
  # `Download.occupying/1` treats a pending `import_next_retry_at` as work still
  # in flight, the episode stayed occupied and was never re-searched. Allow a
  # small budget first: config is applied at boot, so a job that runs during a
  # restart can legitimately see no client for a cycle.
  defp terminal_failure?(:no_client, attempt) when attempt >= 3, do: true
  # A partial import means some files landed and some failed. A couple of
  # retries can pick up a transient per-file failure, but with max_attempts:
  # 1000 an unfixable one re-walks (and historically re-copied) the whole
  # download forever. Cap it so it surfaces as an issue instead. Both the bare
  # atom and the {:partial_import, representative_reason} form must be capped —
  # the tuple carries the underlying cause for the user-facing message and is
  # no less unfixable for it.
  defp terminal_failure?(:partial_import, attempt) when attempt >= 3, do: true
  defp terminal_failure?({:partial_import, _reason}, attempt) when attempt >= 3, do: true
  # Every file resolved to no episode, and the download is flagged
  # unresolved_files for an operator to assign. A few retries let a
  # metadata refresh add a missing episode; past that, re-walking the same
  # files every day changes nothing, and a pending retry keeps the download
  # occupying its target. Stop and leave it in the issues queue.
  defp terminal_failure?(:all_files_unresolved, attempt) when attempt >= 3, do: true
  # Too many distinct files claiming one destination filename. Retrying tries
  # the same exhausted suffixes; the parse or the download contents need
  # looking at.
  defp terminal_failure?({:too_many_conflicts, _path}, _attempt), do: true
  # {:destination_not_accessible, _} is intentionally NOT terminal: it's almost
  # always a fixable library-volume permission/disk issue. Retrying indefinitely
  # lets the import self-heal once the path becomes writable (the exact recovery
  # we want), and keeps the download "occupying" its episode (import_next_retry_at
  # stays set) so the auto-searcher doesn't grab a duplicate release meanwhile.
  defp terminal_failure?(_reason, _attempt), do: false

  defp fetch_download(download_id) do
    case Downloads.get_download(download_id,
           preload: [{:media_item, :episodes}, :episode, :library_path]
         ) do
      nil -> :not_found
      download -> {:ok, download}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Calculate backoff time based on attempt number
    backoff_seconds = Failure.calculate_backoff(attempt)

    Logger.info("Scheduling import retry",
      attempt: attempt,
      backoff_seconds: backoff_seconds,
      next_retry: DateTime.add(DateTime.utc_now(), backoff_seconds, :second)
    )

    backoff_seconds
  end

  ## Private Functions

  defp import_download(download, %Args{target_files: target_files} = args)
       when is_list(target_files) and target_files != [] do
    # Re-import specific files (from resolved file mappings)
    # target_files is a list of %{"path" => path, "episode_id" => id}
    process_targeted_import(download, target_files, args)
  end

  defp import_download(download, args) do
    client_info = Discovery.get_client_info(download)

    if client_info do
      case Discovery.get_download_files(client_info, download) do
        {:ok, files} when files != [] ->
          process_import(download, files, args)

        {:ok, []} ->
          Logger.error("No files found for download", download_id: download.id)
          {:error, :no_files}

        # The client told us exactly which files belong to this download and
        # none of them are on disk. Dropping to the save_path fallback here
        # would recursively sweep a directory the client has already told us
        # is *not* scoped to this download — the exact contamination the file
        # list exists to prevent. Fail instead.
        {:error, {:scoped_files_missing, _count} = error} ->
          {:error, error}

        {:error, error} ->
          Logger.warning("Client query failed, trying save_path fallback",
            download_id: download.id,
            error: inspect(error)
          )

          save_path_fallback(download, args, client_info, error)
      end
    else
      Logger.error("Could not get client info for download", download_id: download.id)
      {:error, :no_client}
    end
  end

  # Last-resort listing when the client cannot tell us which files belong to
  # this download. This walks `save_path` recursively, so it is only safe when
  # `save_path` is specific to this download. Clients that share one output
  # directory across every torrent (rqbit, and qBittorrent for single-file
  # torrents) report the shared root here, and sweeping it copies every
  # neighbouring release into this download's library folder.
  defp save_path_fallback(download, args, client_info, original_error) do
    cond do
      is_nil(args.save_path) or args.save_path == "" ->
        Logger.error("Failed to get download files and no save_path available",
          download_id: download.id,
          error: inspect(original_error)
        )

        {:error, :client_error}

      shared_download_root?(args.save_path, client_info) ->
        Logger.error(
          "Refusing save_path fallback: save_path is the client's download root",
          download_id: download.id,
          save_path: args.save_path,
          download_directory: client_info.download_directory
        )

        {:error, {:save_path_is_download_root, args.save_path}}

      true ->
        do_save_path_fallback(download, args)
    end
  end

  defp do_save_path_fallback(download, args) do
    case Discovery.list_files_in_path(Discovery.mapped_path(args.save_path, download.id)) do
      {:ok, files} when files != [] ->
        Logger.info("Found files via save_path fallback",
          download_id: download.id,
          save_path: args.save_path,
          file_count: length(files)
        )

        process_import(download, files, args)

      {:ok, []} ->
        Logger.error("No files found at save_path",
          download_id: download.id,
          save_path: args.save_path
        )

        {:error, :no_files}

      {:error, path_error} ->
        Logger.error("save_path fallback also failed",
          download_id: download.id,
          save_path: args.save_path,
          error: inspect(path_error)
        )

        {:error, path_error}
    end
  end

  # Delegates to `ImportCandidates.shared_download_root?/2`, the single
  # source of truth for "is the reported save_path the client's configured
  # download directory rather than a per-download subfolder." The manual
  # file matching modal's read path (`ImportCandidates.load/1`) relies on
  # the exact same check before offering a live re-listing, so the two can
  # never silently disagree about what is safe to enumerate.
  defp shared_download_root?(save_path, client_info) do
    ImportCandidates.shared_download_root?(save_path, Map.get(client_info, :download_directory))
  end

  defp process_import(download, files, args) do
    library_path = Paths.determine_library_path(download)

    result =
      case require_library(library_path) do
        {:ok, library_path} ->
          # The resolved library path's auto_rename policy is authoritative at
          # execution time: it drives renaming in both directions, overriding
          # whatever rename_files the job was enqueued with.
          args = %{args | rename_files: library_path.auto_rename}

          do_process_import(download, files, library_path, args)

        {:error, :no_library_path} = error ->
          Logger.error("Could not determine library path for download",
            download_id: download.id
          )

          error
      end

    snapshot_candidates_on_failure(result, download, files, library_path)
  end

  # Persist what the download actually contained whenever the import fails after
  # the file listing succeeded. Without this the operator sees only an error
  # string and has no way to inspect or hand-match the files.
  defp snapshot_candidates_on_failure({:error, _reason} = result, download, files, library_path) do
    library_type = if library_path, do: library_path.type, else: :unknown

    candidates = ImportCandidates.build(files, library_type, FileImport.parser_opts_for(download))

    # Reload rather than starting from the `download` struct captured before
    # `do_process_import/4` ran: `flag_unresolved_files/2` (called from
    # `FileImport.organize_and_import_files/4` on the all-unresolved and partial-import
    # paths) already wrote its own metadata to the row by the time this runs.
    # Merging onto the stale in-memory struct would blindly overwrite that
    # write instead of layering on top of it.
    #
    # The row can also be gone by now — an operator dismissing the download
    # while a large import is still copying files, for example — so this
    # mirrors `fetch_download/1`'s rescue rather than letting a raised
    # `Ecto.NoResultsError` crash the job. There is nothing left to attach a
    # candidate listing to, so skip the snapshot and hand back the original
    # result untouched; the job still fails/succeeds exactly as it would have
    # without this snapshot step.
    case fetch_current_download(download.id) do
      {:ok, current} ->
        metadata =
          (current.metadata || %{})
          |> Map.put("import_candidates", candidates)
          |> Map.put("import_candidates_at", DateTime.utc_now() |> DateTime.to_iso8601())

        case Downloads.update_download(current, %{metadata: metadata}) do
          {:ok, _updated} ->
            :ok

          {:error, changeset} ->
            Logger.warning("Failed to store import candidates",
              download_id: download.id,
              errors: inspect(changeset.errors)
            )
        end

      :not_found ->
        Logger.info("Skipping import candidate snapshot: download row no longer exists",
          download_id: download.id
        )
    end

    result
  end

  defp snapshot_candidates_on_failure(result, _download, _files, _library_path), do: result

  defp fetch_current_download(download_id) do
    case Downloads.get_download(download_id) do
      nil -> :not_found
      download -> {:ok, download}
    end
  end

  defp do_process_import(download, files, library_path, args) do
    case FileImport.organize_and_import_files(download, files, library_path, args) do
      {:ok, imported_files, placed_sources, placement} ->
        Logger.info("Successfully imported files",
          download_id: download.id,
          file_count: length(imported_files)
        )

        # Detect partial season packs: a download that claimed to deliver N
        # episodes but actually matched fewer. Sets match_status accordingly
        # so future re-imports and reporting can recognize it.
        partial_pack_status = FileImport.detect_partial_pack(download, imported_files)

        # Reload download to check if it was flagged as having unresolved files.
        # Falling back to the pre-import struct covers the row being deleted
        # between the file placement above and this read (issue #281): the files
        # are already on disk, so aborting here would be strictly worse than
        # reading a `match_status` written seconds ago by this same call stack.
        updated_download =
          Downloads.get_download(download.id,
            preload: [{:media_item, :episodes}, :episode, :library_path]
          ) || download

        has_unresolved = updated_download.match_status == "unresolved_files"

        # Cleanup is only safe when every file resolved — keep the
        # download in the client when some files remain unmatched so
        # the user can manually retry after fixing the matches.
        unless has_unresolved do
          case ClientRemoval.maybe_remove_after_import(download) do
            :removed ->
              Logger.info("Removed download from client after import",
                download_id: download.id
              )

            result when result in [:deferred, :still_seeding] ->
              Logger.info("Keeping download in client until seeding finishes",
                download_id: download.id
              )

            :skipped ->
              Logger.info("Keeping download in client (remove_completed disabled)",
                download_id: download.id
              )

            {:error, reason} ->
              Logger.warning("Post-import client removal failed",
                download_id: download.id,
                error: inspect(reason)
              )
          end
        end

        # Always stamp `imported_at` once we've made an honest attempt,
        # even when some files are still unresolved. `match_status` keeps
        # surfacing the partial result in the Issues tab. The previous
        # behaviour left `imported_at` nil on partial imports, which
        # caused DownloadMonitor.list_stuck_downloads/1 to re-flag the
        # download every poll and enqueue a fresh MediaImport job every
        # 2 minutes — a retry loop that did no useful work but kept
        # showing "Import stalled - never ran" in the UI.
        import_update =
          %{imported_at: DateTime.utc_now()}
          |> then(fn attrs ->
            # Preserve `match_status: "unresolved_files"` when present so
            # the Issues tab can still surface partial imports. Only
            # touch match_status when we're transitioning to a clean
            # state (partial_pack or nil), never overwrite the
            # in-progress "unresolved_files" flag.
            if has_unresolved do
              attrs
            else
              Map.put(attrs, :match_status, partial_pack_status)
            end
          end)

        import_update =
          Placement.attach_placement(import_update, updated_download.metadata, placement)

        case Downloads.update_download(updated_download, import_update) do
          {:ok, _updated} ->
            Placement.cleanup_sources(
              placed_sources,
              args,
              download,
              library_path.type,
              not has_unresolved
            )

            # A successful import means whatever this item grabbed was real,
            # so the consecutive-auto-rejection counter that
            # Mydia.Jobs.DownloadMonitor keeps must not carry over. Without
            # this, three genuine malware rejections would permanently
            # disable auto-rejection for the item.
            if download.media_item_id do
              Mydia.Search.reset_backoff("auto_reject", download.media_item_id)
            end

            Logger.info("Download marked as imported",
              download_id: download.id,
              has_unresolved: has_unresolved
            )

          {:error, changeset} ->
            Logger.warning("Failed to mark download as imported",
              download_id: download.id,
              errors: inspect(changeset.errors)
            )
        end

        # Write NFO metadata files if enabled for this library path
        if download.media_item_id do
          NfoWriter.maybe_write_nfos(download.media_item_id)
        end

        # Notify native media servers (Jellyfin) to scan for new content
        # This is fire-and-forget (async) - errors won't affect import success
        MediaServerNotifier.notify_all()

        if has_unresolved do
          Logger.info("Partial import complete, unresolved files flagged",
            download_id: download.id
          )

          {:ok, :partial_import}
        else
          {:ok, :imported}
        end

      {:error, reason} ->
        Logger.error("Failed to import files",
          download_id: download.id,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp process_targeted_import(download, target_files, args) do
    # Import specific files with pre-assigned episode IDs (from resolved file mappings)
    case require_library(Paths.determine_library_path(download)) do
      {:ok, library_path} ->
        do_process_targeted_import(download, target_files, library_path, args)

      {:error, :no_library_path} = error ->
        Logger.error("Could not determine library path for targeted import",
          download_id: download.id
        )

        error
    end
  end

  # Turns "no library resolved" into an error before any file operation.
  defp require_library(nil), do: {:error, :no_library_path}
  defp require_library(library_path), do: {:ok, library_path}

  defp do_process_targeted_import(download, target_files, library_path, args) do
    results =
      Enum.map(target_files, fn target ->
        path = target["path"]
        episode_id = target["episode_id"]

        if File.exists?(path) do
          episode = if episode_id, do: Media.get_episode!(Scope.system(), episode_id), else: nil
          file = %{path: path, name: Path.basename(path), size: File.stat!(path).size}

          # Build destination path for this episode
          dest_dir =
            if episode && download.media_item do
              base_dir = Paths.build_series_base_path(download.media_item, library_path, episode)

              Paths.season_dir(base_dir, download.media_item, library_path, episode.season_number)
            else
              Paths.build_destination_path(download, library_path)
            end

          Placement.import_file_to_destination(
            file,
            episode,
            dest_dir,
            download,
            library_path,
            args
          )
        else
          Logger.warning("Target file no longer exists", path: path, download_id: download.id)
          {:error, :file_not_found}
        end
      end)

    errors = Enum.filter(results, &match?({:error, _}, &1))

    if errors == [] do
      # All targeted files imported — clear match_status and the stale
      # candidate/unresolved-file listings. Without dropping
      # "import_candidates" and "import_candidates_at" too, a hand-matched
      # download would keep carrying the listing (and probe verdicts) from
      # the failure this import just resolved, forever.
      current_metadata = download.metadata || %{}

      target_paths = Enum.map(target_files, & &1["path"])
      placement = Placement.placement_summary(target_paths, results, library_path, args)

      cleaned_metadata =
        current_metadata
        |> Map.delete("unresolved_files")
        |> Map.delete("import_candidates")
        |> Map.delete("import_candidates_at")
        |> Placement.put_placement(placement)

      case Downloads.update_download(download, %{
             imported_at: DateTime.utc_now(),
             match_status: nil,
             metadata: cleaned_metadata
           }) do
        {:ok, _updated} ->
          placed = Placement.placed_sources(target_paths, results)
          Placement.cleanup_sources(placed, args, download, library_path.type, true)

        {:error, _changeset} ->
          :ok
      end

      MediaServerNotifier.notify_all()
      {:ok, :imported}
    else
      Logger.warning("Partial targeted import failure",
        download_id: download.id,
        error_count: length(errors)
      )

      # Same treatment as the bulk path: carry the representative reason so a
      # user who just hand-resolved these files is told why it failed.
      {:error, {:partial_import, FileImport.representative_error(errors)}}
    end
  end

  ## Paths

  defdelegate determine_library_path(download), to: Mydia.Jobs.MediaImport.Paths
  defdelegate build_destination_path(download, library_path), to: Mydia.Jobs.MediaImport.Paths
  defdelegate build_series_base_path(media_item, library_path), to: Mydia.Jobs.MediaImport.Paths

  defdelegate build_series_base_path(media_item, library_path, episode),
    to: Mydia.Jobs.MediaImport.Paths

  defdelegate season_dir(base, media_item, library_path, season), to: Mydia.Jobs.MediaImport.Paths

  defdelegate generate_filename(download, episode, original_filename, rename_files?),
    to: Mydia.Jobs.MediaImport.Paths

  ## FileImport

  defdelegate detect_partial_pack(download, imported_files), to: Mydia.Jobs.MediaImport.FileImport
end
