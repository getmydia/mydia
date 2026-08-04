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
  2. Move (when use_hardlinks=false and move_files=true)
  3. Copy (default, safest option)
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 1000,
    # Full incomplete-state set: every normal caller (queue.ex, DownloadMonitor,
    # the downloads LiveView) gets full duplicate protection, including against
    # a MediaImport job that's already :executing for the same download_id.
    # `schedule_snooze_retry/2` below is the one exception — it overrides
    # `:states` at the call site to drop `:executing`, since it needs to
    # self-reinsert while its own parent job is still running.
    unique: [
      period: 600,
      keys: [:download_id],
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  require Logger
  alias Mydia.{Downloads, Library, Media, Settings}
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.ImportCandidates
  alias Mydia.Library.{FileNamer, FileOrganizer, SampleDetector}
  alias Mydia.Library.ReleaseParser
  alias Mydia.Library.ReleaseParser.TargetContext
  alias Mydia.Indexers.QualityParser
  alias Mydia.MediaServer.Notifier, as: MediaServerNotifier
  alias Mydia.Metadata.NfoWriter
  alias Mydia.Settings.LibraryPath
  alias Mydia.Upgrades

  defmodule Args do
    @moduledoc false
    defstruct [
      :download_id,
      :target_files,
      :save_path,
      snooze_count: 0,
      use_hardlinks: true,
      move_files: false,
      rename_files: false
    ]

    @type t :: %__MODULE__{
            download_id: String.t() | nil,
            target_files: [map()] | nil,
            save_path: String.t() | nil,
            snooze_count: integer(),
            use_hardlinks: boolean(),
            move_files: boolean(),
            rename_files: boolean()
          }

    def parse(%{"download_id" => download_id} = raw) do
      %__MODULE__{
        download_id: download_id,
        target_files: Map.get(raw, "target_files"),
        save_path: parse_save_path(Map.get(raw, "save_path")),
        snooze_count: Map.get(raw, "snooze_count", 0),
        use_hardlinks: Map.get(raw, "use_hardlinks", true) != false,
        move_files: Map.get(raw, "move_files", false) == true,
        rename_files: Map.get(raw, "rename_files", false) == true
      }
    end

    defp parse_save_path(save_path) when save_path in [nil, ""], do: nil
    defp parse_save_path(save_path) when is_binary(save_path), do: save_path
  end

  # Exponential backoff schedule in seconds
  # 1 min, 5 min, 15 min, 1 hour, 4 hours, 12 hours, 24 hours, then 24 hours indefinitely
  @backoff_schedule [60, 300, 900, 3600, 14_400, 43_200, 86_400]

  # Snooze settings for waiting on incomplete downloads
  # 5 minutes between snoozes, max 12 snoozes (1 hour total)
  @snooze_interval_seconds 300
  @max_snooze_count 12

  # How many `name.N.ext` variants to try when a destination filename is taken
  # by different content. Deliberately small: more than a handful of distinct
  # files claiming one episode's filename means the parse is wrong, and
  # numbering on forever is what let one bad import fill a disk.
  @max_conflict_suffixes 10

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
        handle_incomplete_download(download, args, attempt, raw_args)

      true ->
        case import_download(download, args) do
          {:ok, result} ->
            # Success - clear any retry metadata
            clear_retry_metadata(download)
            {:ok, result}

          {:error, reason} ->
            # Failure - update retry metadata. If the failure is structurally
            # unfixable (e.g. a completed torrent contains zero importable
            # media files, or its save path has been gone for several
            # attempts), stop Oban's retry loop so the row doesn't keep
            # re-scanning for days.
            terminal? = terminal_failure?(reason, attempt)
            handle_import_failure(download, reason, attempt, terminal?: terminal?)

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
    {:ok,
     Downloads.get_download!(download_id,
       preload: [{:media_item, :episodes}, :episode, :library_path]
     )}
  rescue
    Ecto.NoResultsError -> :not_found
  end

  defp handle_incomplete_download(download, args, attempt, raw_args) do
    download_id = download.id
    snooze_count = args.snooze_count

    if snooze_count >= @max_snooze_count do
      # Hit max snooze count - mark as failed so it appears in Issues tab
      Logger.warning(
        "Download not completed after #{snooze_count} snoozes (~1 hour), marking as failed",
        download_id: download_id,
        snooze_count: snooze_count
      )

      handle_import_failure(download, :download_not_completed, attempt)
      {:error, :download_not_completed}
    else
      Logger.info("Download not completed, scheduling retry import job",
        download_id: download_id,
        snooze_count: snooze_count + 1,
        max_snooze_count: @max_snooze_count,
        next_check_in_seconds: @snooze_interval_seconds
      )

      # Schedule a new job with incremented snooze count
      # We can't use {:snooze, seconds} because it doesn't update args
      schedule_snooze_retry(download_id, snooze_count + 1, raw_args)
      {:ok, :waiting_for_completion}
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Calculate backoff time based on attempt number
    backoff_seconds = calculate_backoff(attempt)

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
    client_info = get_client_info(download)

    if client_info do
      case get_download_files(client_info, download) do
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
    case list_files_in_path(mapped_path(args.save_path, download.id)) do
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

  # True when the reported save_path is the client's configured download
  # directory rather than a per-download subfolder. Compared after path
  # mapping so a remote root and its local mount both match.
  defp shared_download_root?(save_path, %{download_directory: root})
       when is_binary(save_path) and save_path != "" and is_binary(root) and root != "" do
    same_dir?(save_path, root) or
      same_dir?(mapped_path_quiet(save_path), mapped_path_quiet(root))
  end

  defp shared_download_root?(_save_path, _client_info), do: false

  defp same_dir?(a, b) when is_binary(a) and a != "" and is_binary(b) and b != "",
    do: Path.expand(a) == Path.expand(b)

  defp same_dir?(_a, _b), do: false

  defp process_import(download, files, args) do
    library_path = determine_library_path(download)

    result =
      if library_path do
        # The resolved library path's auto_rename policy is authoritative at
        # execution time: it drives renaming in both directions, overriding
        # whatever rename_files the job was enqueued with.
        args = %{args | rename_files: library_path.auto_rename}

        do_process_import(download, files, library_path, args)
      else
        Logger.error("Could not determine library path for download", download_id: download.id)
        {:error, :no_library_path}
      end

    snapshot_candidates_on_failure(result, download, files, library_path)
  end

  # Persist what the download actually contained whenever the import fails after
  # the file listing succeeded. Without this the operator sees only an error
  # string and has no way to inspect or hand-match the files.
  defp snapshot_candidates_on_failure({:error, _reason} = result, download, files, library_path) do
    library_type = if library_path, do: library_path.type, else: :unknown

    candidates = ImportCandidates.build(files, library_type, parser_opts_for(download))

    # Reload rather than starting from the `download` struct captured before
    # `do_process_import/4` ran: `flag_unresolved_files/2` (called from
    # `organize_and_import_files/4` on the all-unresolved and partial-import
    # paths) already wrote its own metadata to the row by the time this runs.
    # Merging onto the stale in-memory struct would blindly overwrite that
    # write instead of layering on top of it.
    current = Downloads.get_download!(download.id)

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

    result
  end

  defp snapshot_candidates_on_failure(result, _download, _files, _library_path), do: result

  defp do_process_import(download, files, library_path, args) do
    case organize_and_import_files(download, files, library_path, args) do
      {:ok, imported_files} ->
        Logger.info("Successfully imported files",
          download_id: download.id,
          file_count: length(imported_files)
        )

        # Detect partial season packs: a download that claimed to deliver N
        # episodes but actually matched fewer. Sets match_status accordingly
        # so future re-imports and reporting can recognize it.
        partial_pack_status = detect_partial_pack(download, imported_files)

        # Reload download to check if it was flagged as having unresolved files
        updated_download =
          Downloads.get_download!(download.id,
            preload: [{:media_item, :episodes}, :episode, :library_path]
          )

        has_unresolved = updated_download.match_status == "unresolved_files"

        # Cleanup is only safe when every file resolved — keep the
        # download in the client when some files remain unmatched so
        # the user can manually retry after fixing the matches.
        unless has_unresolved do
          client_info = get_client_info(download)
          should_cleanup = client_info && client_info.remove_completed

          if should_cleanup do
            Logger.info("Removing download from client (remove_completed enabled)",
              download_id: download.id,
              client: download.download_client
            )

            cleanup_download_client(download)
          else
            Logger.info("Keeping download in client for seeding (remove_completed disabled)",
              download_id: download.id,
              client: download.download_client
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

        case Downloads.update_download(updated_download, import_update) do
          {:ok, _updated} ->
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

        # Notify media servers (Plex, Jellyfin) to scan for new content
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
    library_path = determine_library_path(download)

    if is_nil(library_path) do
      Logger.error("Could not determine library path for targeted import",
        download_id: download.id
      )

      {:error, :no_library_path}
    else
      results =
        Enum.map(target_files, fn target ->
          path = target["path"]
          episode_id = target["episode_id"]

          if File.exists?(path) do
            episode = if episode_id, do: Media.get_episode!(episode_id), else: nil
            file = %{path: path, name: Path.basename(path), size: File.stat!(path).size}

            # Build destination path for this episode
            dest_dir =
              if episode && download.media_item do
                base_dir = build_series_base_path(download.media_item, library_path)

                Path.join(
                  base_dir,
                  "Season #{String.pad_leading("#{episode.season_number}", 2, "0")}"
                )
              else
                build_destination_path(download, library_path)
              end

            import_file_to_destination(file, episode, dest_dir, download, library_path, args)
          else
            Logger.warning("Target file no longer exists", path: path, download_id: download.id)
            {:error, :file_not_found}
          end
        end)

      errors = Enum.filter(results, &match?({:error, _}, &1))

      if errors == [] do
        # All targeted files imported — clear match_status and unresolved_files metadata
        current_metadata = download.metadata || %{}
        cleaned_metadata = Map.delete(current_metadata, "unresolved_files")

        Downloads.update_download(download, %{
          imported_at: DateTime.utc_now(),
          match_status: nil,
          metadata: cleaned_metadata
        })

        MediaServerNotifier.notify_all()
        {:ok, :imported}
      else
        Logger.warning("Partial targeted import failure",
          download_id: download.id,
          error_count: length(errors)
        )

        # Same treatment as the bulk path: carry the representative reason so a
        # user who just hand-resolved these files is told why it failed.
        {:error, {:partial_import, representative_error(errors)}}
      end
    end
  end

  defp get_client_info(download) do
    if download.download_client && download.download_client_id do
      # Search both database and runtime config clients
      client_config =
        Settings.list_download_client_configs()
        |> Enum.find(&(&1.name == download.download_client))

      if client_config do
        adapter = Client.Registry.lookup(client_config.type)

        %{
          adapter: adapter,
          config: build_client_config(client_config),
          client_id: download.download_client_id,
          remove_completed: Map.get(client_config, :remove_completed, false),
          download_directory: Map.get(client_config, :download_directory)
        }
      end
    end
  end

  defp get_download_files(client_info, download) do
    case Client.get_status(client_info.adapter, client_info.config, client_info.client_id) do
      {:ok, status} ->
        resolve_status_files(status, download.id)

      {:error, error} ->
        {:error, error}
    end
  end

  # Prefer the client's explicit per-torrent file list when available. Falling
  # back to a recursive listing of `save_path` is unsafe for clients (rqbit)
  # that share one output folder across many torrents — that path is what
  # cross-contaminated series libraries on galactica.
  defp resolve_status_files(%{files: files}, download_id)
       when is_list(files) and files != [] do
    resolved =
      files
      |> Enum.map(&mapped_path(&1, download_id))
      |> Enum.flat_map(&file_entry_if_exists/1)

    case resolved do
      [] ->
        Logger.warning("Torrent file list resolved to no existing paths",
          download_id: download_id,
          listed_count: length(files)
        )

        {:error, {:scoped_files_missing, length(files)}}

      entries ->
        {:ok, entries}
    end
  end

  defp resolve_status_files(%{save_path: save_path}, download_id)
       when is_binary(save_path) and save_path != "" do
    save_path
    |> mapped_path(download_id)
    |> list_files_in_path()
  end

  defp resolve_status_files(_status, download_id) do
    Logger.warning("No save_path in status", download_id: download_id)
    {:error, :no_save_path}
  end

  defp file_entry_if_exists(path) do
    cond do
      not File.exists?(path) ->
        []

      File.dir?(path) ->
        list_files_recursive(path)

      true ->
        [
          %{
            path: path,
            name: Path.basename(path),
            size: File.stat!(path).size
          }
        ]
    end
  rescue
    _e in File.Error ->
      []
  end

  # Apply configured remote→local path mappings before touching the filesystem,
  # logging the rewrite when one applies so the original and mapped paths are
  # both visible in the import logs.
  defp mapped_path(reported_path, download_id) do
    case Mydia.Library.PathMapping.rewrite(reported_path) do
      ^reported_path ->
        reported_path

      mapped ->
        Logger.info("Applied path mapping",
          download_id: download_id,
          reported_path: reported_path,
          mapped_path: mapped
        )

        mapped
    end
  end

  # Same rewrite without the log line, for comparisons that are not about to
  # touch the filesystem.
  defp mapped_path_quiet(path) when is_binary(path),
    do: Mydia.Library.PathMapping.rewrite(path)

  defp mapped_path_quiet(path), do: path

  defp list_files_in_path(path) do
    path_stat = File.stat(path)
    parent_stat = File.stat(Path.dirname(path))

    cond do
      stat_eacces?(path_stat) or stat_eacces?(parent_stat) ->
        {:error, {:path_not_accessible, path}}

      File.exists?(path) ->
        if File.dir?(path) do
          files = list_files_recursive(path)
          {:ok, files}
        else
          [
            %{
              path: path,
              name: Path.basename(path),
              size: File.stat!(path).size
            }
          ]
          |> then(&{:ok, &1})
        end

      # Parent directory is visible but the leaf is gone — a genuinely missing
      # or deleted file. Keep the existing message.
      File.exists?(Path.dirname(path)) ->
        {:error, {:path_not_found, path}}

      # Even the immediate parent isn't visible inside Mydia's filesystem — this
      # is the container volume mount-mismatch signature, not a deleted file.
      true ->
        {:error, {:path_mapping_mismatch, path}}
    end
  rescue
    _e in File.Error ->
      {:error, {:path_not_accessible, path}}
  end

  defp stat_eacces?({:error, :eacces}), do: true
  defp stat_eacces?(_), do: false

  defp list_files_recursive(dir) do
    File.ls!(dir)
    |> Enum.flat_map(fn entry ->
      full_path = Path.join(dir, entry)

      cond do
        File.regular?(full_path) ->
          [
            %{
              path: full_path,
              name: Path.basename(full_path),
              size: File.stat!(full_path).size
            }
          ]

        File.dir?(full_path) ->
          list_files_recursive(full_path)

        true ->
          []
      end
    end)
  end

  @doc false
  def determine_library_path(download) do
    # If download has a direct library_path association (specialized libraries),
    # use that directly
    if download.library_path do
      download.library_path
    else
      # Get library paths from settings
      library_paths = Settings.list_library_paths()

      {media_type, required_types} =
        cond do
          # TV episode
          download.episode && download.media_item ->
            {"TV show", [:series, :mixed]}

          # Movie
          download.media_item && download.media_item.type == "movie" ->
            {"movie", [:movies, :mixed]}

          # TV show (no specific episode)
          download.media_item && download.media_item.type == "tv_show" ->
            {"TV show", [:series, :mixed]}

          true ->
            {"unknown", [:mixed]}
        end

      # Find compatible library path
      library_path =
        Enum.find(library_paths, fn lp ->
          lp.type in required_types && lp.monitored
        end)

      # Log warning if no compatible library found
      if is_nil(library_path) do
        Logger.warning("No compatible library path found for import",
          download_id: download.id,
          media_type: media_type,
          required_library_types: required_types,
          available_libraries:
            Enum.map(library_paths, fn lp ->
              %{path: lp.path, type: lp.type, monitored: lp.monitored}
            end)
        )
      end

      library_path
    end
  end

  defp organize_and_import_files(download, files, library_path, args) do
    # Determine which files to import based on library type
    files_to_import = filter_files_for_library_type(files, library_path.type)

    # Filter out extras, samples, and trailers
    files_to_import = filter_extras_and_samples(files_to_import)
    parser_opts = parser_opts_for(download)

    if files_to_import == [] do
      Logger.warning("No importable files found in download",
        download_id: download.id,
        library_type: library_path.type
      )

      {:error, :no_importable_files}
    else
      # Import each file - destination path is determined per-file for TV shows.
      # Wrap each per-file import so a raised exception (e.g. a filesystem error
      # from a bang call deep in the path) is captured as {:error, ...} and
      # routed through handle_import_failure, instead of crashing the Oban job
      # silently and leaving the download stuck with no error on its row.
      results =
        Enum.map(files_to_import, fn file ->
          try do
            import_file(file, download, library_path, args, parser_opts)
          rescue
            exception ->
              Logger.error("Unhandled exception importing file",
                download_id: download.id,
                file: file.name,
                exception: Exception.message(exception),
                stacktrace: Exception.format_stacktrace(__STACKTRACE__)
              )

              {:error, {:import_exception, Exception.message(exception)}}
          end
        end)

      # Separate results into imported, unresolved, and errors
      {imported, unresolved, errors} =
        Enum.reduce(results, {[], [], []}, fn
          {:ok, media_file}, {imp, unr, err} -> {[media_file | imp], unr, err}
          {:unresolved, file_info}, {imp, unr, err} -> {imp, [file_info | unr], err}
          {:error, _} = error, {imp, unr, err} -> {imp, unr, [error | err]}
        end)

      imported = Enum.reverse(imported)
      unresolved = Enum.reverse(unresolved)

      cond do
        # All files imported successfully
        unresolved == [] and errors == [] ->
          {:ok, imported}

        # Some files imported, some unresolved (partial import)
        unresolved != [] and imported != [] ->
          flag_unresolved_files(download, unresolved)
          {:ok, imported}

        # No files imported, all unresolved
        unresolved != [] and imported == [] ->
          flag_unresolved_files(download, unresolved)
          {:error, :all_files_unresolved}

        # Total failure (nothing imported, nothing unresolved — only errors).
        # Surface a representative error reason instead of a generic
        # :partial_import so retry/terminal classification and the user-facing
        # message reflect the real cause (e.g. {:path_not_accessible, dir} when a
        # whole destination directory is unwritable, which is terminal after a
        # few attempts rather than retrying forever).
        imported == [] ->
          {:error, representative_error(errors)}

        # Some files imported, some failed — keep the partial-import signal so
        # the successfully-imported files are not undone by a terminal cancel,
        # but attach the representative underlying reason so the user-facing
        # message reflects the real cause instead of a generic hint.
        true ->
          {:error, {:partial_import, representative_error(errors)}}
      end
    end
  end

  # Picks a single error reason to represent a batch of per-file failures. When
  # the failures are uniform (the common case — e.g. the entire season directory
  # is unwritable) the first reason represents them all.
  defp representative_error([{:error, reason} | _]), do: reason
  defp representative_error(_), do: :partial_import

  # Returns "partial_pack" if a season-pack download delivered fewer distinct
  # episodes than the search-time metadata promised; otherwise nil. The infinite
  # re-download loop we hit in prod was bogus "season packs" that contained a
  # single episode file — without this check, the download was marked as
  # successfully imported and the next hourly search re-grabbed it.
  @doc false
  def detect_partial_pack(download, imported_files) do
    metadata = download.metadata || %{}
    expected_count = metadata["episode_count"]

    if not is_integer(expected_count) or expected_count <= 0 do
      nil
    else
      actual_count =
        imported_files
        |> Enum.map(& &1.episode_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> length()

      if actual_count < expected_count do
        Logger.warning("Season pack delivered fewer episodes than promised",
          download_id: download.id,
          title: download.title,
          expected_episode_count: expected_count,
          matched_episode_count: actual_count
        )

        "partial_pack"
      end
    end
  end

  defp flag_unresolved_files(download, unresolved_files) do
    # Store unresolved file info in metadata and set match_status
    current_metadata = download.metadata || %{}

    unresolved_data =
      Enum.map(unresolved_files, fn file_info ->
        %{
          "path" => file_info.path,
          "name" => file_info.name,
          "size" => file_info.size,
          "parsed_season" => file_info.parsed_season,
          "parsed_episode" => file_info.parsed_episode,
          "assigned_episode_id" => nil
        }
      end)

    updated_metadata = Map.put(current_metadata, "unresolved_files", unresolved_data)

    case Downloads.update_download(download, %{
           match_status: "unresolved_files",
           metadata: updated_metadata
         }) do
      {:ok, _updated} ->
        Logger.info("Flagged download with #{length(unresolved_files)} unresolved file(s)",
          download_id: download.id
        )

        Downloads.broadcast_download_update(download.id)

      {:error, changeset} ->
        Logger.warning("Failed to flag unresolved files",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )
    end
  end

  @doc false
  def build_destination_path(download, library_path) when is_struct(library_path, LibraryPath) do
    # Use FileOrganizer for category-aware destination paths when auto_organize is enabled
    cond do
      # Movie with auto_organize enabled
      download.media_item && download.media_item.type == "movie" && library_path.auto_organize ->
        FileOrganizer.destination_path(download.media_item, library_path)

      # TV episode - always use show folder + season subfolder
      download.episode && download.media_item ->
        # Get base folder (potentially category-aware)
        base_folder =
          if library_path.auto_organize do
            FileOrganizer.destination_path(download.media_item, library_path)
          else
            title = sanitize_filename(download.media_item.title)
            Path.join(library_path.path, title)
          end

        season = download.episode.season_number
        Path.join(base_folder, "Season #{String.pad_leading("#{season}", 2, "0")}")

      # Movie without auto_organize
      download.media_item && download.media_item.type == "movie" ->
        title = sanitize_filename(download.media_item.title)
        year = download.media_item.year

        if year do
          Path.join([library_path.path, "#{title} (#{year})"])
        else
          Path.join([library_path.path, title])
        end

      # TV show (no specific episode) - use category-aware path if enabled
      download.media_item && download.media_item.type == "tv_show" ->
        if library_path.auto_organize do
          FileOrganizer.destination_path(download.media_item, library_path)
        else
          title = sanitize_filename(download.media_item.title)
          Path.join(library_path.path, title)
        end

      # Unknown - use download title
      true ->
        title = sanitize_filename(download.title)
        Path.join(library_path.path, title)
    end
  end

  # Legacy clause for string library_root (used internally)
  def build_destination_path(download, library_root) when is_binary(library_root) do
    cond do
      # TV episode
      download.episode && download.media_item ->
        title = sanitize_filename(download.media_item.title)
        season = download.episode.season_number

        Path.join([library_root, title, "Season #{String.pad_leading("#{season}", 2, "0")}"])

      # Movie
      download.media_item && download.media_item.type == "movie" ->
        title = sanitize_filename(download.media_item.title)
        year = download.media_item.year

        if year do
          Path.join([library_root, "#{title} (#{year})"])
        else
          Path.join([library_root, title])
        end

      # TV show (no specific episode) - fallback
      download.media_item && download.media_item.type == "tv_show" ->
        title = sanitize_filename(download.media_item.title)
        Path.join([library_root, title])

      # Unknown - use download title
      true ->
        title = sanitize_filename(download.title)
        Path.join([library_root, title])
    end
  end

  # Helper to build category-aware base path for TV series
  @doc false
  def build_series_base_path(media_item, library_path) do
    if library_path.auto_organize do
      FileOrganizer.destination_path(media_item, library_path)
    else
      title = sanitize_filename(media_item.title)
      Path.join(library_path.path, title)
    end
  end

  defp sanitize_filename(filename) do
    filename
    |> String.replace(~r/[<>:"|?*]/, "")
    |> String.replace(~r/[\/\\]/, "-")
    |> String.trim()
  end

  # The extension vocabulary lives in `ImportCandidates`, which also derives the
  # skip reasons shown to the operator on a failed import. Keeping one copy means
  # the two can never disagree.
  defp filter_files_for_library_type(files, library_type) do
    Enum.filter(files, &ImportCandidates.importable?(&1, library_type))
  end

  defp filter_extras_and_samples(files) do
    Enum.reject(files, fn file ->
      if SampleDetector.skip_detection?(file.path) do
        false
      else
        detection = SampleDetector.detect(file.path)

        if SampleDetector.excluded?(detection) do
          Logger.info("Skipping extra/sample/trailer file during import",
            path: file.path,
            reason: SampleDetector.exclusion_reason(detection)
          )

          true
        else
          false
        end
      end
    end)
  end

  # Build a `%TargetContext{}` from the download's preloaded
  # `%MediaItem{}` (with `:episodes`). Returns `nil` when the download
  # has no bound media item — the parser then runs unbound and infers
  # type/title/year from the filename.
  defp target_context_for(%{media_item: %Mydia.Media.MediaItem{} = media_item}) do
    TargetContext.from_media_item(media_item)
  end

  defp target_context_for(_download), do: nil

  defp parser_opts_for(download) do
    case target_context_for(download) do
      nil -> []
      target -> [target: target]
    end
  end

  # Ensure `Media.refresh_episodes_for_tv_show/1` is invoked at most once
  # per Oban job per show. Each Oban worker call runs in its own process,
  # so the process dictionary gives us a job-scoped memoization key that
  # cleans itself up automatically when the job exits.
  #
  # The dedup target is the media_item id, not the season — a single
  # refresh call always pulls every season's episodes for the show, so
  # repeating it for another season number in the same job is pure waste.
  defp refresh_episodes_once(%Mydia.Media.MediaItem{id: id} = media_item, season) do
    key = {:media_import_refresh_attempted, id}

    if Process.get(key) do
      :already_attempted
    else
      Process.put(key, true)

      Logger.info("Episode not found, refreshing episodes for TV show",
        media_item: media_item.title,
        season: season
      )

      case Media.refresh_episodes_for_tv_show(media_item) do
        {:ok, count} ->
          Logger.info("Refreshed episodes, created #{count} episodes")
          {:ok, count}

        {:error, reason} = error ->
          Logger.error("Failed to refresh episodes",
            media_item: media_item.title,
            reason: inspect(reason)
          )

          error
      end
    end
  end

  defp import_file(file, download, library_path, args, parser_opts) do
    # Parse filename to extract episode info for TV shows. When the
    # download is already bound to a known `%MediaItem{}`, pass it as
    # a `%TargetContext{}` so the parser locks type / title / year and
    # focuses on season + episode + quality.
    parsed = ReleaseParser.parse(file.name, parser_opts)

    # Check if this is a season pack download
    is_season_pack = get_in(download.metadata, ["season_pack"]) == true
    season_pack_season = get_in(download.metadata, ["season_number"])

    # Determine episode and destination path
    {episode, dest_dir} =
      case {download.media_item, download.episode, parsed.type, is_season_pack} do
        # Season pack - the per-file filename is the authoritative season
        # hint when the parser found one. The download-level
        # `season_number` is only the originally-requested season; for
        # "Complete S01-S03" style packs containing files from multiple
        # seasons, every file would otherwise be force-matched to that
        # one season and most would fall through to `:unresolved` (or
        # worse, collapse onto a single episode row when episode_number
        # collides). Prefer parsed.season; fall back to season_pack_season
        # for files where the parser couldn't recover a season token.
        {%{type: "tv_show"} = media_item, _, :tv_show, true}
        when not is_nil(season_pack_season) and not is_nil(parsed.episodes) ->
          episode_number = List.first(parsed.episodes) || 1
          file_season = parsed.season || season_pack_season

          Logger.debug("Processing season pack file",
            file: file.name,
            season_pack_season: season_pack_season,
            file_season: file_season,
            episode_number: episode_number
          )

          episode =
            Media.get_episode_by_number(
              media_item.id,
              file_season,
              episode_number
            )

          episode =
            if is_nil(episode) do
              # Refresh metadata at most ONCE per import job per show.
              # Calling refresh per-file was the metadata-relay hammer
              # behind the Good Omens incident: the in-memory media_item
              # struct stays stale across this Enum.map loop, so
              # `should_skip_season_refresh?` never tripped and every
              # unresolved file fired a fresh HTTP round-trip. After this
              # guard, the first miss does the refresh, subsequent misses
              # in the same job re-use whatever the refresh produced (or
              # the empty result if refresh failed).
              refresh_episodes_once(media_item, file_season)

              # Retry episode lookup regardless of refresh result —
              # another file in this same job may have just created the
              # episode row we need.
              Media.get_episode_by_number(
                media_item.id,
                file_season,
                episode_number
              )
            else
              episode
            end

          if episode do
            Logger.debug("Found episode for season pack file",
              file: file.name,
              season: file_season,
              episode: episode_number,
              episode_id: episode.id
            )

            # Build destination path using the matched episode's actual
            # season — not the download-level season — so files from
            # `Complete S01-S03` packs land in the right `Season XX` dirs.
            base_dir = build_series_base_path(media_item, library_path)

            dest_dir =
              Path.join(base_dir, "Season #{String.pad_leading("#{file_season}", 2, "0")}")

            {episode, dest_dir}
          else
            Logger.warning("Episode still not found after refresh attempt",
              file: file.name,
              season: file_season,
              episode: episode_number,
              media_item: media_item.title
            )

            # Return :unresolved instead of importing with nil episode
            {:unresolved,
             %{
               path: file.path,
               name: file.name,
               size: file.size,
               parsed_season: file_season,
               parsed_episode: episode_number
             }}
          end

        # TV show with parsed episode info - look up the episode
        {%{type: "tv_show"} = media_item, _, :tv_show, _}
        when not is_nil(parsed.season) and not is_nil(parsed.episodes) ->
          episode_number = List.first(parsed.episodes) || 1

          episode =
            Media.get_episode_by_number(
              media_item.id,
              parsed.season,
              episode_number
            )

          if episode do
            Logger.debug("Found episode for file",
              file: file.name,
              season: parsed.season,
              episode: episode_number,
              episode_id: episode.id
            )

            # Build destination path using parsed season info (category-aware)
            base_dir = build_series_base_path(media_item, library_path)

            dest_dir =
              Path.join(base_dir, "Season #{String.pad_leading("#{parsed.season}", 2, "0")}")

            {episode, dest_dir}
          else
            Logger.warning("Episode not found in database, falling back to download episode",
              file: file.name,
              season: parsed.season,
              episode: episode_number,
              media_item: media_item.title
            )

            # Fall back to download episode and default path (category-aware)
            dest_dir = build_destination_path(download, library_path)
            {download.episode, dest_dir}
          end

        # TV show file where the parser found a season but no episode
        # number (e.g. `Show.S01.mkv`, or season-pack files that don't
        # carry an `SxxEyy` marker). Don't silently default to episode 1
        # — return :unresolved so the file shows up in the issues queue
        # for manual resolution.
        {%{type: "tv_show"} = media_item, _, :tv_show, _}
        when not is_nil(parsed.season) and is_nil(parsed.episodes) ->
          Logger.warning("TV file has parseable season but no episode number — skipping",
            file: file.name,
            season: parsed.season,
            media_item: media_item.title
          )

          {:unresolved,
           %{
             path: file.path,
             name: file.name,
             size: file.size,
             parsed_season: parsed.season,
             parsed_episode: nil
           }}

        # TV show but no parsed info - use download episode
        {%{type: "tv_show"}, episode, _, _} when not is_nil(episode) ->
          dest_dir = build_destination_path(download, library_path)
          {episode, dest_dir}

        # Movie or other - use download info (category-aware)
        _ ->
          dest_dir = build_destination_path(download, library_path)
          {download.episode, dest_dir}
      end

    # Handle unresolved files (season pack files where episode wasn't found)
    case {episode, dest_dir} do
      {:unresolved, file_info} ->
        {:unresolved, file_info}

      {episode, dest_dir} ->
        import_file_to_destination(file, episode, dest_dir, download, library_path, args)
    end
  end

  defp import_file_to_destination(file, episode, dest_dir, download, library_path, args) do
    # Ensure destination directory exists. Use the non-raising variant so a
    # permission/filesystem error becomes a handled {:error, ...} that flows
    # through handle_import_failure (persisting import_last_error and surfacing
    # in the UI) instead of crashing the Oban job silently.
    case File.mkdir_p(dest_dir) do
      :ok ->
        import_file_to_existing_dir(file, episode, dest_dir, download, library_path, args)

      {:error, reason} ->
        Logger.error("Failed to create destination directory",
          dest_dir: dest_dir,
          reason: inspect(reason)
        )

        {:error, {:destination_not_accessible, dest_dir}}
    end
  end

  defp import_file_to_existing_dir(file, episode, dest_dir, download, library_path, args) do
    # Generate filename (optionally renamed with TRaSH format)
    final_filename = generate_filename(download, episode, file.name, args.rename_files)
    dest_path = Path.join(dest_dir, final_filename)

    # Check if file already exists
    if File.exists?(dest_path) do
      Logger.warning("File already exists at destination",
        source: file.path,
        dest: dest_path
      )

      # Try to find existing media_file record
      case Library.get_media_file_by_path(dest_path) do
        nil ->
          # File exists but not in DB - this is a conflict
          handle_file_conflict(file, dest_path, episode, download, library_path, args)

        existing_file ->
          # File exists and is in DB - reuse it
          Logger.info("Reusing existing media file", path: dest_path)
          {:ok, existing_file}
      end
    else
      # Copy or move file. `:expected_size` closes the window between the
      # File.exists?/1 check above and the placement itself: a concurrent
      # import that already wrote the right bytes is adopted rather than
      # hardlinked-onto-EEXIST and re-copied.
      case copy_or_move_file(file.path, dest_path, args, expected_size: file.size) do
        :ok ->
          create_media_file_record(dest_path, file.size, episode, download, library_path)

        {:error, reason} ->
          Logger.error("Failed to copy/move file",
            source: file.path,
            dest: dest_path,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    end
  end

  defp handle_file_conflict(file, dest_path, episode, download, library_path, args) do
    if file_size(dest_path) == file.size do
      # Files are likely identical - create DB record
      Logger.info("File sizes match, creating DB record", path: dest_path)
      create_media_file_record(dest_path, file.size, episode, download, library_path)
    else
      place_conflicting_file(file, dest_path, episode, download, library_path, args)
    end
  end

  defp place_conflicting_file(file, dest_path, episode, download, library_path, args) do
    case resolve_conflict_path(dest_path, file.size) do
      {:existing, path} ->
        # A previous attempt already placed this exact file under a conflict
        # suffix. Adopt it instead of copying the bytes again.
        Logger.info("Reusing conflict copy placed by an earlier attempt", path: path)
        create_media_file_record(path, file.size, episode, download, library_path)

      {:new, path} ->
        Logger.info("File conflict, using unique name", new_path: path)

        case copy_or_move_file(file.path, path, args, expected_size: file.size) do
          :ok -> create_media_file_record(path, file.size, episode, download, library_path)
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        Logger.error("Could not find a free conflict filename",
          dest: dest_path,
          reason: inspect(reason)
        )

        {:error, reason}
    end
  end

  # Picks the destination for a file whose ideal name is already taken by
  # different content.
  #
  # This used to append `DateTime.to_unix()`, which made every retry of a
  # failed import mint a brand-new filename and re-copy the whole file. With
  # `max_attempts: 1000` that is how a handful of misplaced episodes became
  # ~980 GiB of duplicates in production. Numbering deterministically means a
  # retry lands on the same candidate, sees the file it wrote last time, and
  # adopts it instead of copying again.
  #
  # Returns `{:existing, path}` when a suffixed sibling already holds content
  # of the expected size, `{:new, path}` for the lowest free suffix, or
  # `{:error, {:too_many_conflicts, dest}}` once the suffix budget is spent.
  defp resolve_conflict_path(dest_path, size) do
    ext = Path.extname(dest_path)
    base = Path.basename(dest_path, ext)
    dir = Path.dirname(dest_path)

    Enum.reduce_while(1..@max_conflict_suffixes, nil, fn n, _acc ->
      candidate = Path.join(dir, "#{base}.#{n}#{ext}")

      cond do
        not File.exists?(candidate) -> {:halt, {:new, candidate}}
        file_size(candidate) == size -> {:halt, {:existing, candidate}}
        true -> {:cont, nil}
      end
    end)
    |> case do
      nil -> {:error, {:too_many_conflicts, dest_path}}
      result -> result
    end
  end

  # File.stat/1 rather than File.stat!/1: the caller has already checked the
  # path exists, but a file that vanishes in between should not crash the job.
  defp file_size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      {:error, _} -> nil
    end
  end

  defp copy_or_move_file(source, dest, %Args{} = args, opts) do
    # Import keeps the source file (seeding) after a hardlink, so
    # remove_source_after_hardlink stays false. Non-hardlink fallback is move
    # only when move_files is set, otherwise copy.
    #
    # `:expected_size` lets FileOrganizer treat an already-correct destination
    # as placed instead of hardlinking onto EEXIST and falling through to a
    # full copy — the difference between a retry being free and a retry
    # duplicating the file.
    place_opts =
      Keyword.merge(
        [
          use_hardlinks: args.use_hardlinks,
          fallback: if(args.move_files, do: :move, else: :copy)
        ],
        opts
      )

    case FileOrganizer.place_file(source, dest, place_opts) do
      {:ok, action} ->
        Logger.debug("Placed file", from: source, to: dest, action: action)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  def generate_filename(download, episode, original_filename, rename_files?)
      when is_boolean(rename_files?) do
    # Only rename if explicitly enabled (default: false for safety)
    if rename_files? do
      # Parse quality information from download title or original filename
      quality_info =
        QualityParser.parse(download.title || original_filename)

      media_item = download.media_item

      cond do
        # TV episode with episode info
        media_item.type == "tv_show" && not is_nil(episode) ->
          FileNamer.generate_episode_filename(
            media_item,
            episode,
            quality_info,
            original_filename
          )

        # Movie
        media_item.type == "movie" ->
          FileNamer.generate_movie_filename(
            media_item,
            quality_info,
            original_filename
          )

        # Fallback to original filename
        true ->
          original_filename
      end
    else
      # Renaming disabled - use original filename
      original_filename
    end
  end

  defp create_media_file_record(path, size, episode, download, library_path) do
    # Extract metadata from filename first (as fallback). Quality only —
    # no `%TargetContext{}` needed here.
    filename_metadata = ReleaseParser.parse(Path.basename(path))

    Logger.debug("Parsed filename metadata",
      path: path,
      resolution: filename_metadata.quality.resolution,
      codec: filename_metadata.quality.codec,
      audio: filename_metadata.quality.audio
    )

    # Calculate relative path from absolute path and library path
    relative_path = Path.relative_to(path, library_path.path)

    Logger.debug("Storing media file with relative path",
      absolute_path: path,
      library_path: library_path.path,
      relative_path: relative_path,
      library_path_id: library_path.id
    )

    # Tech metadata (codec/resolution/bitrate/hdr_format) is left nil at import
    # time; the row is picked up by `Mydia.Jobs.FileAnalysis` which fills it via
    # the shared `Library.apply_analysis/2` write. We still record filename-derived
    # values as the initial best guess so quality-profile selection has something
    # to work with before analysis lands.
    attrs = %{
      relative_path: relative_path,
      library_path_id: library_path.id,
      size: size,
      resolution: filename_metadata.quality.resolution,
      codec: filename_metadata.quality.codec,
      audio_codec: filename_metadata.quality.audio,
      hdr_format: filename_metadata.quality.hdr_format,
      verified_at: DateTime.utc_now(),
      metadata: %{
        imported_from_download_id: download.id,
        imported_at: DateTime.utc_now(),
        source: filename_metadata.quality.source,
        release_group: filename_metadata.release_group,
        download_client: download.download_client,
        download_client_id: download.download_client_id
      }
    }

    # Use the episode parameter if provided, otherwise fall back to download associations
    # For specialized libraries (music, books, adult), there may be no media_item/episode
    attrs =
      cond do
        episode && episode.id ->
          Map.merge(attrs, %{
            episode_id: episode.id,
            media_item_id: nil
          })

        download.episode_id ->
          Map.merge(attrs, %{
            episode_id: download.episode_id,
            media_item_id: nil
          })

        download.media_item_id ->
          Map.merge(attrs, %{
            media_item_id: download.media_item_id,
            episode_id: nil
          })

        # Specialized library download (music, books, adult) - no media_item needed
        download.library_path_id && library_path.type in [:music, :books, :adult] ->
          Logger.debug("Creating media file for specialized library",
            library_type: library_path.type,
            download_id: download.id
          )

          Map.merge(attrs, %{
            episode_id: nil,
            media_item_id: nil
          })

        true ->
          Logger.error("No episode_id or media_item_id available", download_id: download.id)
          attrs
      end

    # A season pack carries one target id but delivers many episodes. Each
    # episode supersedes its OWN current best file, not the download's
    # single target, which is what lets an above-cutoff episode keep its
    # file when the gate in Task 10 (UpgradeFinalize) rejects the pack's
    # version for it. A movie import is the degenerate single-file case of
    # the same rule.
    attrs =
      Map.put(
        attrs,
        :supersedes_media_file_id,
        supersede_target(download, Map.get(attrs, :media_item_id), Map.get(attrs, :episode_id))
      )

    case Library.create_media_file(attrs) do
      {:ok, media_file} ->
        Logger.info("Created media file record",
          path: path,
          id: media_file.id,
          episode_id: media_file.episode_id,
          resolution: media_file.resolution,
          codec: media_file.codec
        )

        {:ok, media_file}

      {:error, changeset} ->
        # Check if this is a library type mismatch error
        if has_library_type_mismatch_error?(changeset) do
          media_type = if episode, do: "TV show", else: "movie"

          Logger.error("Library type mismatch during import",
            path: path,
            media_type: media_type,
            download_id: download.id,
            media_item_id: download.media_item_id,
            episode_id: episode && episode.id,
            errors: format_changeset_errors(changeset)
          )

          {:error, :library_type_mismatch}
        else
          Logger.error("Failed to create media file record",
            path: path,
            errors: inspect(changeset.errors)
          )

          {:error, :database_error}
        end
    end
  end

  # Only an upgrade-triggered download carries "upgrade_target_media_file_id"
  # in its metadata; every ordinary import falls through the `_ -> nil` clause
  # without running the lookup below, so the hot path for the common case
  # (no upgrade in play) stays a single map pattern match.
  #
  # For an upgrade import, `Upgrades.current_best_file_id/2` resolves what
  # THIS specific file (identified by its own media_item_id/episode_id, not
  # the download's) currently supersedes.
  defp supersede_target(download, media_item_id, episode_id) do
    case download.metadata do
      %{"upgrade_target_media_file_id" => target_id} when is_binary(target_id) ->
        resolve_supersede_target(target_id, media_item_id, episode_id)

      _ ->
        nil
    end
  end

  # Episodes: deliberately NO fallback to the download's single target_id. A
  # season pack shares one target across many episodes, so an episode with no
  # existing file of its own would inherit some OTHER episode's target id —
  # exactly the cross-episode mistake this per-file resolution exists to
  # avoid. `nil` correctly means "nothing to supersede for this file".
  defp resolve_supersede_target(_target_id, _media_item_id, episode_id)
       when is_binary(episode_id) do
    Upgrades.current_best_file_id(nil, episode_id)
  end

  # Movies: one target, one file, no siblings to confuse it with, so the
  # cross-episode hazard above cannot apply. Fall back to the target the sweep
  # picked when the per-file lookup comes up empty — which it does whenever the
  # quality profile stops resolving (deleted between grab and import) or the
  # old file is no longer scorable. Leaving the pointer nil there would strand
  # the upgrade: `UpgradeFinalize` only runs for a non-nil pointer, so the
  # superseded file would never be trashed, the library would keep both copies,
  # and `Health.upgrade_health/0` — which counts stale pointers — could not see
  # it. A target that has since vanished is safe: a trash lands on
  # `:orphaned` and a hard delete nilifies the FK (`on_delete: :nilify_all`),
  # both of which clear the pointer and keep the new file.
  defp resolve_supersede_target(target_id, media_item_id, nil) do
    Upgrades.current_best_file_id(media_item_id, nil) || target_id
  end

  defp cleanup_download_client(download) do
    client_info = get_client_info(download)

    if client_info do
      case Client.remove_download(
             client_info.adapter,
             client_info.config,
             client_info.client_id,
             delete_files: true
           ) do
        :ok ->
          Logger.info("Removed download from client", download_id: download.id)

        {:error, error} ->
          Logger.warning("Failed to remove download from client",
            download_id: download.id,
            error: inspect(error)
          )
      end
    end
  end

  defp build_client_config(client_config) do
    case client_config.type do
      :blackhole ->
        # Blackhole uses connection_settings for folder paths
        %{
          type: :blackhole,
          connection_settings: client_config.connection_settings || %{}
        }

      :debrid ->
        # Debrid reads the provider sub-selector from
        # `connection_settings["provider"]` and the operator's bearer token
        # from `api_key`. Without these the dispatch returns :invalid_config.
        %{
          type: :debrid,
          api_key: client_config.api_key,
          download_directory: client_config.download_directory,
          connection_settings: client_config.connection_settings || %{}
        }

      _ ->
        # Network-based clients
        %{
          type: client_config.type,
          host: client_config.host,
          port: client_config.port,
          username: client_config.username,
          password: client_config.password,
          use_ssl: client_config.use_ssl || false,
          options:
            %{}
            |> maybe_put(:url_base, client_config.url_base)
            |> maybe_put(:api_key, client_config.api_key)
        }
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Checks if a changeset has a library type mismatch error
  defp has_library_type_mismatch_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, {message, _opts}} ->
      (field == :media_item_id or field == :episode_id) and
        (String.contains?(message, "cannot add movies to a library") or
           String.contains?(message, "cannot add TV episodes to a library"))
    end)
  end

  # Formats changeset errors for logging
  defp format_changeset_errors(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
      "#{field}: #{message}"
    end)
  end

  # Calculate exponential backoff based on attempt number
  defp calculate_backoff(attempt) do
    # Attempt is 1-indexed, but we want 0-indexed for the schedule
    index = attempt - 1

    # For attempts within our schedule, use the configured value
    if index < length(@backoff_schedule) do
      Enum.at(@backoff_schedule, index)
    else
      # For attempts beyond our schedule, use the last value (24 hours)
      List.last(@backoff_schedule)
    end
  end

  # Update download record with retry metadata after a failed attempt.
  # When `terminal?: true` is passed, clears `import_next_retry_at` so the
  # UI can show "gave up" instead of advertising a retry that will never fire.
  defp handle_import_failure(download, reason, attempt, opts \\ []) do
    terminal? = Keyword.get(opts, :terminal?, false)

    next_retry_at =
      if terminal? do
        nil
      else
        DateTime.add(DateTime.utc_now(), calculate_backoff(attempt), :second)
      end

    error_message = format_import_error(reason, download)
    import_failed_at = download.import_failed_at || DateTime.utc_now()

    attrs = %{
      import_retry_count: attempt,
      import_last_error: error_message,
      import_failure_reason: failure_reason_tag(reason),
      import_reported_path: failure_reported_path(reason),
      import_next_retry_at: next_retry_at,
      import_failed_at: import_failed_at
    }

    case Downloads.update_download(download, attrs) do
      {:ok, _updated} ->
        if terminal? do
          Logger.warning("Import failed terminally — no further retries",
            download_id: download.id,
            attempt: attempt,
            reason: error_message
          )
        else
          Logger.warning("Import failed, will retry",
            download_id: download.id,
            attempt: attempt,
            reason: error_message,
            next_retry_at: next_retry_at
          )
        end

        :ok

      {:error, changeset} ->
        Logger.error("Failed to update retry metadata",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  # Structured failure classification persisted alongside the human message, so
  # the Issues tab can filter (e.g. on "path_mapping_mismatch") without parsing
  # prose.
  defp failure_reason_tag({tag, _path}) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_reason_tag(tag) when is_atom(tag), do: Atom.to_string(tag)
  defp failure_reason_tag(_), do: nil

  # The client-reported path Mydia could not see, persisted for path-bearing
  # failures so the Issues tab can compute a mapping suggestion later.
  #
  # {:partial_import, reason} is explicitly not path-bearing: its second element
  # is an underlying failure reason, which can itself be a string. Letting it
  # fall through would feed prose to the Issues tab's path-mapping suggester.
  defp failure_reported_path({:partial_import, _reason}), do: nil
  defp failure_reported_path({_tag, path}) when is_binary(path), do: path
  defp failure_reported_path(_), do: nil

  # Format error messages with actionable context for users
  defp format_import_error(:no_client, download) do
    client_name = download.download_client || "Unknown"

    "Download client '#{client_name}' not found in settings. " <>
      "Check Settings → Download Clients and verify the client is configured."
  end

  defp format_import_error(:client_error, download) do
    client_name = download.download_client || "Unknown"

    "Cannot connect to download client '#{client_name}'. " <>
      "Check that the client is running and accessible from the server."
  end

  defp format_import_error(:no_files, _download) do
    "No files found in download location. " <>
      "The download may have been moved, deleted, or is still extracting. " <>
      "Import will retry automatically."
  end

  defp format_import_error({:too_many_conflicts, path}, _download) do
    "Too many different files want the same library filename: #{path}. " <>
      "The download probably contains several releases parsed as the same " <>
      "episode. Check its contents before retrying."
  end

  defp format_import_error({:scoped_files_missing, count}, download) do
    client_name = download.download_client || "the download client"

    "#{client_name} listed #{count} file(s) for this download, but none of them " <>
      "exist where Mydia looked. The client's paths likely differ from Mydia's " <>
      "view of the same volume — add a path mapping or fix the mount."
  end

  defp format_import_error({:save_path_is_download_root, path}, download) do
    client_name = download.download_client || "The download client"

    "#{client_name} reports this download's location as its own download root " <>
      "(#{path}) instead of a folder for this release. Importing from there " <>
      "would pull in every other download in that directory, so it was refused. " <>
      "Enable per-torrent subfolders in the client, or clear the client's " <>
      "download directory setting in Settings → Download Clients if it is wrong."
  end

  defp format_import_error({:path_mapping_mismatch, path}, _download) do
    "Mydia can't access the download path: #{path}. " <>
      "This usually means the download client's volume isn't mounted into the " <>
      "Mydia container at the same path. Add a path mapping or fix the mount."
  end

  defp format_import_error({:path_not_found, path}, _download) do
    "Download path not found: #{path}. " <>
      "The download may have been moved, deleted, or not yet available."
  end

  defp format_import_error({:path_not_accessible, path}, _download) do
    "Download path is not accessible: #{path}. " <>
      "Check filesystem permissions and path accessibility."
  end

  defp format_import_error({:destination_not_accessible, path}, _download) do
    "Could not create the library destination directory: #{path}. " <>
      "Check filesystem permissions and available disk space on the library volume. " <>
      "Import will retry automatically once the path is writable."
  end

  defp format_import_error(:no_library_path, download) do
    media_type = get_media_type_name(download)

    "No library configured for #{media_type}. " <>
      "Add a compatible library in Settings → Libraries."
  end

  defp format_import_error(:no_importable_files, download) do
    media_type = get_media_type_name(download)

    "No importable files found for #{media_type}. " <>
      "The download may contain only non-media files (samples, NFO, etc.)."
  end

  defp format_import_error(:partial_import, _download) do
    "Some files could not be imported. " <>
      "Check library path permissions and available disk space."
  end

  defp format_import_error({:partial_import, inner_reason}, _download) do
    "Some files could not be imported. " <>
      "First error: #{format_error_detail(inner_reason)}"
  end

  defp format_import_error({:import_exception, message}, _download) do
    "Unexpected error during import: #{first_line(message)}. " <>
      "Import will retry automatically."
  end

  defp format_import_error(:download_not_completed, download) do
    client_name = download.download_client || "Unknown"

    "Download not yet complete in '#{client_name}' after waiting ~1 hour. " <>
      "Check the download client for errors or stalled downloads."
  end

  defp format_import_error(:library_type_mismatch, download) do
    media_type = get_media_type_name(download)

    "Cannot import #{media_type} to the configured library. " <>
      "The library type doesn't match the media type (e.g., trying to add movies to a TV library)."
  end

  defp format_import_error(:database_error, _download) do
    "Database error while creating file records. " <>
      "This may be a temporary issue. Import will retry automatically."
  end

  defp format_import_error(reason, _download) when is_atom(reason) do
    # Fallback for unknown atom errors
    reason |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp format_import_error(reason, _download) when is_binary(reason) do
    reason
  end

  defp format_import_error(reason, _download) do
    inspect(reason)
  end

  # Renders the underlying per-file failure reason compactly for inclusion in
  # user-facing messages.
  defp format_error_detail({:import_exception, message}), do: first_line(message)

  defp format_error_detail(reason) when is_atom(reason) do
    reason |> Atom.to_string() |> String.replace("_", " ")
  end

  defp format_error_detail(reason) when is_binary(reason), do: first_line(reason)

  defp format_error_detail(reason), do: inspect(reason)

  # Exception messages can be huge — an Ecto error embeds the whole query — and
  # these end up in `import_last_error`, which the UI renders inline. Keep the
  # first non-empty line. Falls back to a placeholder rather than crashing: this
  # runs inside failure reporting, where raising would lose the original error
  # and leave the download with no message at all.
  defp first_line(message) when is_binary(message) do
    message
    |> String.split("\n", trim: true)
    |> Enum.find_value("(no details)", fn line ->
      trimmed = String.trim(line)
      trimmed != "" and trimmed
    end)
  end

  defp first_line(message), do: inspect(message)

  # Helper to get a human-readable media type name
  defp get_media_type_name(download) do
    cond do
      download.episode && download.media_item ->
        "TV show episode"

      download.media_item && download.media_item.type == "movie" ->
        "movie"

      download.media_item && download.media_item.type == "tv_show" ->
        "TV show"

      download.library_path && download.library_path.type == :music ->
        "music"

      download.library_path && download.library_path.type == :books ->
        "book"

      download.library_path && download.library_path.type == :adult ->
        "adult content"

      true ->
        "media"
    end
  end

  # Clear retry metadata after successful import
  defp clear_retry_metadata(download) do
    # Only clear if there was a previous failure
    if download.import_failed_at do
      attrs = %{
        import_retry_count: 0,
        import_last_error: nil,
        import_next_retry_at: nil,
        import_failed_at: nil
      }

      case Downloads.update_download(download, attrs) do
        {:ok, _updated} ->
          Logger.info("Import succeeded after #{download.import_retry_count} retries",
            download_id: download.id
          )

          :ok

        {:error, changeset} ->
          Logger.warning("Failed to clear retry metadata",
            download_id: download.id,
            errors: inspect(changeset.errors)
          )

          :ok
      end
    end
  end

  # Schedule a retry job when download is not yet completed
  # Uses a new job with updated snooze_count to track how long we've been waiting
  defp schedule_snooze_retry(download_id, new_snooze_count, original_args) do
    scheduled_at = DateTime.add(DateTime.utc_now(), @snooze_interval_seconds, :second)

    # Preserve original args but update snooze_count
    new_args =
      original_args
      |> Map.put("snooze_count", new_snooze_count)

    # This job is currently :executing (schedule_snooze_retry/2 only runs from
    # inside perform/1), so the unique states are narrowed to drop :executing
    # here — otherwise Oban would see this insert as colliding with its own
    # still-running parent and silently discard the snooze. See the `unique`
    # comment on `use Oban.Worker` above for the full policy this overrides.
    changeset =
      __MODULE__.new(new_args,
        scheduled_at: scheduled_at,
        unique: [states: [:suspended, :available, :scheduled, :retryable]]
      )

    # Use Oban.insert if available, otherwise fall back to Repo.insert for testing
    result =
      try do
        Oban.insert(changeset)
      rescue
        RuntimeError ->
          # In testing mode without running Oban, insert directly via Repo
          Mydia.Repo.insert(changeset)
      end

    case result do
      {:ok, job} ->
        Logger.debug("Scheduled snooze retry job",
          download_id: download_id,
          job_id: job.id,
          snooze_count: new_snooze_count,
          scheduled_at: scheduled_at
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule snooze retry job",
          download_id: download_id,
          reason: inspect(reason)
        )

        :error
    end
  end
end
