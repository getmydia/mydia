defmodule Mydia.Jobs.LibraryScanner do
  @moduledoc """
  Background job for scanning the media library.

  This job:
  - Scans configured library paths for media files
  - Detects new, modified, and deleted files
  - Updates the database with file information
  - Tracks scan status and errors

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

  # Upper bound of the insert-time jitter applied to automatic scans.
  @max_startup_delay_ms 30 * 60 * 1000

  alias Mydia.Library.{
    FileIngest,
    MetadataMatcher,
    MusicScanner,
    BookScanner,
    AdultScanner,
    SampleDetector,
    ScanSummary
  }

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

  defp scan_library_path(library_path) do
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

    # Perform the file system scan with appropriate extensions for library type
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
      process_scan_result_by_type(library_path, scan_result)
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

  # Dispatch to appropriate scanner based on library type
  defp process_scan_result_by_type(library_path, scan_result) do
    result =
      case library_path.type do
        :music ->
          process_music_scan_result(library_path, scan_result)

        :books ->
          process_books_scan_result(library_path, scan_result)

        :adult ->
          process_adult_scan_result(library_path, scan_result)

        # Video-based library types use the standard video processing
        type when type in [:movies, :series, :mixed] ->
          process_scan_result(library_path, scan_result)

        # Default to video processing for unknown types
        _ ->
          process_scan_result(library_path, scan_result)
      end

    summarize(result)
  end

  # The per-type processors return two different shapes: the video processor
  # returns lists under :changes, the others return integer counts. Normalize
  # both into a ScanSummary so callers have a single contract.
  defp summarize({:ok, %{changes: changes} = details}) do
    {:ok,
     %ScanSummary{
       new_files: length(changes.new_files),
       modified_files: length(changes.modified_files),
       deleted_files: length(changes.deleted_files),
       details: details
     }}
  end

  defp summarize(
         {:ok, %{new_files: new, modified_files: modified, deleted_files: deleted} = details}
       )
       when is_integer(new) and is_integer(modified) and is_integer(deleted) do
    {:ok,
     %ScanSummary{
       new_files: new,
       modified_files: modified,
       deleted_files: deleted,
       details: details
     }}
  end

  # Errors from handle_scan_error/2 pass through unchanged.
  defp summarize(other), do: other

  defp process_music_scan_result(library_path, scan_result) do
    Logger.info("Processing music library scan",
      library_path_id: library_path.id,
      files_found: length(scan_result.files)
    )

    result = MusicScanner.process_scan_result(library_path, scan_result)

    # Update library path with success status
    if updatable_library_path?(library_path) do
      {:ok, _} =
        Settings.update_library_path(library_path, %{
          last_scan_at: DateTime.utc_now(),
          last_scan_status: :success,
          last_scan_error: nil
        })
    end

    # Broadcast scan completed
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "library_scanner",
      {:library_scan_completed,
       %{
         library_path_id: library_path.id,
         type: library_path.type,
         new_files: result.new_files,
         modified_files: result.modified_files,
         deleted_files: result.deleted_files
       }}
    )

    {:ok, result}
  rescue
    error ->
      error_message = Exception.format(:error, error, __STACKTRACE__)
      Logger.error("Music library scan raised exception", error: error_message)
      handle_scan_error(library_path, error_message)
  end

  defp process_books_scan_result(library_path, scan_result) do
    Logger.info("Processing books library scan",
      library_path_id: library_path.id,
      files_found: length(scan_result.files)
    )

    result = BookScanner.process_scan_result(library_path, scan_result)

    # Update library path with success status
    if updatable_library_path?(library_path) do
      {:ok, _} =
        Settings.update_library_path(library_path, %{
          last_scan_at: DateTime.utc_now(),
          last_scan_status: :success,
          last_scan_error: nil
        })
    end

    # Broadcast scan completed
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "library_scanner",
      {:library_scan_completed,
       %{
         library_path_id: library_path.id,
         type: library_path.type,
         new_files: result.new_files,
         modified_files: result.modified_files,
         deleted_files: result.deleted_files
       }}
    )

    {:ok, result}
  rescue
    error ->
      error_message = Exception.format(:error, error, __STACKTRACE__)
      Logger.error("Books library scan raised exception", error: error_message)
      handle_scan_error(library_path, error_message)
  end

  defp process_adult_scan_result(library_path, scan_result) do
    Logger.info("Processing adult library scan",
      library_path_id: library_path.id,
      files_found: length(scan_result.files)
    )

    # Process adult content metadata (studios, scenes, adult_files)
    adult_result = AdultScanner.process_scan_result(library_path, scan_result)

    # Also process as standard media files for thumbnails and playback
    # Get existing media files from database
    existing_files = Library.list_media_files(library_path_id: library_path.id)

    # Detect changes using the shared scanner logic
    changes = Library.Scanner.detect_changes(scan_result, existing_files, library_path)

    # Create MediaFile records for new files (for thumbnails and playback)
    new_media_file_ids =
      Enum.flat_map(changes.new_files, fn file_info ->
        relative_path = Path.relative_to(file_info.path, library_path.path)

        case Library.create_scanned_media_file(%{
               library_path_id: library_path.id,
               relative_path: relative_path,
               size: file_info.size,
               verified_at: DateTime.utc_now()
             }) do
          {:ok, media_file} ->
            Logger.debug("Created media file for adult content",
              path: file_info.path,
              media_file_id: media_file.id
            )

            [media_file.id]

          {:error, changeset} ->
            Logger.error("Failed to create media file for adult content",
              path: file_info.path,
              errors: inspect(changeset.errors)
            )

            []
        end
      end)

    # Update modified files
    Enum.each(changes.modified_files, fn file_info ->
      relative_path = Path.relative_to(file_info.path, library_path.path)

      case Library.get_media_file_by_relative_path(library_path.id, relative_path) do
        nil ->
          Logger.warning("Modified file not found in database",
            path: file_info.path,
            relative_path: relative_path
          )

        media_file ->
          Library.update_media_file(media_file, %{
            size: file_info.size,
            verified_at: DateTime.utc_now()
          })
      end
    end)

    # Trash removed files (soft-delete for recovery)
    Enum.each(changes.deleted_files, fn media_file ->
      Library.trash_media_file(media_file)
    end)

    # Find existing files missing thumbnails
    existing_files_missing_thumbnails =
      existing_files
      |> Enum.filter(&is_nil(&1.cover_blob))
      |> Enum.map(& &1.id)

    # Combine new files and existing files missing thumbnails
    files_needing_thumbnails = new_media_file_ids ++ existing_files_missing_thumbnails

    # Enqueue thumbnail generation for all files needing thumbnails (includes sprites)
    if files_needing_thumbnails != [] do
      Logger.info("Enqueueing thumbnail generation for adult files",
        new_files: length(new_media_file_ids),
        existing_missing: length(existing_files_missing_thumbnails),
        total: length(files_needing_thumbnails)
      )

      Mydia.Jobs.ThumbnailGeneration.enqueue_batch(files_needing_thumbnails,
        include_sprites: true,
        include_previews: true
      )
    end

    # Update library path with success status
    if updatable_library_path?(library_path) do
      {:ok, _} =
        Settings.update_library_path(library_path, %{
          last_scan_at: DateTime.utc_now(),
          last_scan_status: :success,
          last_scan_error: nil
        })
    end

    # Broadcast scan completed
    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "library_scanner",
      {:library_scan_completed,
       %{
         library_path_id: library_path.id,
         type: library_path.type,
         new_files: adult_result.new_files,
         modified_files: adult_result.modified_files,
         deleted_files: adult_result.deleted_files
       }}
    )

    {:ok, adult_result}
  rescue
    error ->
      error_message = Exception.format(:error, error, __STACKTRACE__)
      Logger.error("Adult library scan raised exception", error: error_message)
      handle_scan_error(library_path, error_message)
  end

  defp process_scan_result(library_path, scan_result) do
    # Get existing files from database - only files within this library path
    # This prevents deleting files from other library paths during scan
    existing_files = Library.list_media_files(library_path_id: library_path.id)

    # Detect changes
    changes = Library.Scanner.detect_changes(scan_result, existing_files, library_path)

    # Filter out extras, samples, and trailers from new files
    {regular_new_files, extras_filtered} =
      Enum.split_with(changes.new_files, fn file_info ->
        SampleDetector.skip_detection?(file_info.path) or
          not SampleDetector.excluded?(SampleDetector.detect(file_info.path))
      end)

    if extras_filtered != [] do
      Logger.info("Filtered #{length(extras_filtered)} sample/trailer/extra files from scan",
        library_path_id: library_path.id
      )
    end

    # Process files in batches to avoid long-running transactions
    batch_size = 100
    total_new_files = length(regular_new_files)
    total_modified = length(changes.modified_files)
    total_deleted = length(changes.deleted_files)

    Logger.info("Processing library changes in batches",
      new_files: total_new_files,
      modified_files: total_modified,
      deleted_files: total_deleted,
      batch_size: batch_size
    )

    # Process new files in batches
    new_media_files =
      regular_new_files
      |> Enum.chunk_every(batch_size)
      |> Enum.with_index()
      |> Enum.flat_map(fn {batch, batch_index} ->
        batch_num = batch_index + 1
        total_batches = ceil(total_new_files / batch_size)

        Logger.debug("Processing new files batch #{batch_num}/#{total_batches}",
          batch_size: length(batch)
        )

        # Broadcast progress
        Phoenix.PubSub.broadcast(
          Mydia.PubSub,
          "library_scanner",
          {:library_scan_progress,
           %{
             library_path_id: library_path.id,
             stage: :creating_files,
             current: batch_index * batch_size + length(batch),
             total: total_new_files
           }}
        )

        # Process batch in a transaction
        {:ok, batch_results} =
          Repo.transaction(fn ->
            Enum.map(batch, fn file_info ->
              # Calculate relative path from library root
              relative_path = Path.relative_to(file_info.path, library_path.path)

              # Check if a trashed file with the same path exists — restore it instead of creating a duplicate
              case Library.get_media_file_by_relative_path(
                     library_path.id,
                     relative_path,
                     include_trashed: true
                   ) do
                %{trashed_at: trashed_at} = trashed_file when not is_nil(trashed_at) ->
                  case Library.restore_media_file(trashed_file) do
                    {:ok, restored_file} ->
                      Logger.info("Restored trashed media file",
                        path: file_info.path,
                        relative_path: relative_path
                      )

                      {:ok, restored_file, file_info}

                    {:error, _reason} ->
                      Logger.error("Failed to restore trashed media file",
                        path: file_info.path,
                        relative_path: relative_path
                      )

                      {:error, file_info}
                  end

                _ ->
                  case Library.create_scanned_media_file(%{
                         library_path_id: library_path.id,
                         relative_path: relative_path,
                         size: file_info.size,
                         verified_at: DateTime.utc_now()
                       }) do
                    {:ok, media_file} ->
                      Logger.debug("Added new media file",
                        path: file_info.path,
                        relative_path: relative_path
                      )

                      {:ok, media_file, file_info}

                    {:error, changeset} ->
                      Logger.error("Failed to create media file",
                        path: file_info.path,
                        errors: inspect(changeset.errors)
                      )

                      {:error, file_info}
                  end
              end
            end)
          end)

        batch_results
      end)

    # Process modified files in batches
    changes.modified_files
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index()
    |> Enum.each(fn {batch, batch_index} ->
      batch_num = batch_index + 1
      total_batches = ceil(total_modified / batch_size)

      Logger.debug("Processing modified files batch #{batch_num}/#{total_batches}",
        batch_size: length(batch)
      )

      # Broadcast progress
      Phoenix.PubSub.broadcast(
        Mydia.PubSub,
        "library_scanner",
        {:library_scan_progress,
         %{
           library_path_id: library_path.id,
           stage: :updating_files,
           current: batch_index * batch_size + length(batch),
           total: total_modified
         }}
      )

      # Process batch in a transaction
      Repo.transaction(fn ->
        Enum.each(batch, fn file_info ->
          # Calculate relative path to find the file in database
          relative_path = Path.relative_to(file_info.path, library_path.path)

          case Library.get_media_file_by_relative_path(
                 library_path.id,
                 relative_path
               ) do
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
      end)
    end)

    # Process deleted files in batches
    changes.deleted_files
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index()
    |> Enum.each(fn {batch, batch_index} ->
      batch_num = batch_index + 1
      total_batches = ceil(total_deleted / batch_size)

      Logger.debug("Processing deleted files batch #{batch_num}/#{total_batches}",
        batch_size: length(batch)
      )

      # Broadcast progress
      Phoenix.PubSub.broadcast(
        Mydia.PubSub,
        "library_scanner",
        {:library_scan_progress,
         %{
           library_path_id: library_path.id,
           stage: :deleting_files,
           current: batch_index * batch_size + length(batch),
           total: total_deleted
         }}
      )

      # Process batch in a transaction — trash instead of hard-delete
      Repo.transaction(fn ->
        Enum.each(batch, fn media_file ->
          # Preload library_path association for path resolution
          media_file = Mydia.Repo.preload(media_file, :library_path)
          absolute_path = Mydia.Library.MediaFile.absolute_path(media_file)

          # These files are missing from disk, which is the one case
          # Library.trash_media_file/1 has nothing to move, so a failure here
          # is a database problem. Log it and keep going rather than raising a
          # MatchError that aborts the whole batch transaction and rolls back
          # every other file in it.
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
      end)
    end)

    # Prepare result for metadata enrichment
    result = %{changes: changes, scan_result: scan_result, new_media_files: new_media_files}

    # Get metadata provider config
    metadata_config = Metadata.default_relay_config()

    # Process metadata enrichment for new files in parallel (outside transaction)
    # Use Task.async_stream for concurrency with back-pressure
    total_to_enrich = Enum.count(result.new_media_files, &match?({:ok, _, _}, &1))

    Logger.info("Starting metadata enrichment",
      total_files: total_to_enrich,
      max_concurrency: 10
    )

    enrichment_results =
      result.new_media_files
      |> Enum.filter(&match?({:ok, _, _}, &1))
      |> Stream.with_index()
      |> Task.async_stream(
        fn {{:ok, media_file, file_info}, index} ->
          # Broadcast progress every 10 files
          if rem(index, 10) == 0 do
            Phoenix.PubSub.broadcast(
              Mydia.PubSub,
              "library_scanner",
              {:library_scan_progress,
               %{
                 library_path_id: library_path.id,
                 stage: :enriching_metadata,
                 current: index,
                 total: total_to_enrich
               }}
            )
          end

          # Try to parse, match, and enrich the file
          process_result = process_media_file(media_file, file_info, metadata_config)
          {media_file, process_result}
        end,
        max_concurrency: 10,
        timeout: :infinity,
        on_timeout: :kill_task
      )
      |> Enum.map(fn
        {:ok, result} ->
          result

        {:exit, reason} ->
          Logger.warning("Metadata enrichment task crashed", reason: inspect(reason))
          nil
      end)
      |> Enum.reject(&is_nil/1)

    # Count type mismatches in new files
    type_mismatch_count =
      Enum.count(enrichment_results, fn {_file, result} ->
        result == {:error, :library_type_mismatch}
      end)

    # Initialize tracking for robust cleanup operations
    cleanup_stats = %{
      orphaned_files_fixed: 0,
      tv_orphans_fixed: 0,
      associations_updated: 0,
      invalid_paths_removed: 0,
      type_mismatches_detected: type_mismatch_count,
      movies_in_series_libs: 0,
      tv_in_movies_libs: 0
    }

    # 1. Re-enrich completely orphaned files (no media_item_id and no episode_id)
    # Skip extras/samples/trailers — they should remain orphaned
    completely_orphaned =
      existing_files
      |> Enum.filter(fn file ->
        is_nil(file.media_item_id) and is_nil(file.episode_id)
      end)
      |> Enum.reject(fn file ->
        file = Mydia.Repo.preload(file, :library_path)
        abs_path = Mydia.Library.MediaFile.absolute_path(file)

        not SampleDetector.skip_detection?(abs_path) and
          SampleDetector.excluded?(SampleDetector.detect(abs_path))
      end)

    cleanup_stats =
      if completely_orphaned != [] do
        Logger.info("Re-enriching completely orphaned files",
          count: length(completely_orphaned)
        )

        fixed_count =
          Enum.count(completely_orphaned, fn media_file ->
            # Preload library_path association for path resolution
            media_file = Mydia.Repo.preload(media_file, :library_path)
            absolute_path = Mydia.Library.MediaFile.absolute_path(media_file)

            file_info =
              Enum.find(result.scan_result.files, fn f -> f.path == absolute_path end)

            if file_info do
              Logger.debug("Re-enriching orphaned file", path: absolute_path)
              process_media_file(media_file, file_info, metadata_config)
              true
            else
              false
            end
          end)

        Map.put(cleanup_stats, :orphaned_files_fixed, fixed_count)
      else
        cleanup_stats
      end

    # 2. Fix orphaned TV show files (have media_item_id for TV show but no episode_id)
    # Preload media_item to check type
    tv_orphaned_files =
      existing_files
      |> Repo.preload(:media_item)
      |> Enum.filter(fn file ->
        not is_nil(file.media_item_id) and
          is_nil(file.episode_id) and
          file.media_item != nil and
          file.media_item.type == "tv_show"
      end)

    cleanup_stats =
      if tv_orphaned_files != [] do
        Logger.info("Fixing orphaned TV show files", count: length(tv_orphaned_files))

        fixed_count =
          Enum.count(tv_orphaned_files, fn media_file ->
            fix_orphaned_tv_file(media_file, metadata_config)
          end)

        Map.put(cleanup_stats, :tv_orphans_fixed, fixed_count)
      else
        cleanup_stats
      end

    # 3. Re-validate file associations for TV shows
    # Check if season/episode info changed by re-parsing filenames
    tv_files_with_episodes =
      existing_files
      |> Repo.preload([:media_item, :episode])
      |> Enum.filter(fn file ->
        not is_nil(file.episode_id) and file.episode != nil
      end)

    cleanup_stats =
      if tv_files_with_episodes != [] do
        Logger.debug("Re-validating TV file associations",
          count: length(tv_files_with_episodes)
        )

        updated_count =
          Enum.count(tv_files_with_episodes, fn media_file ->
            revalidate_tv_file_association(media_file)
          end)

        Map.put(cleanup_stats, :associations_updated, updated_count)
      else
        cleanup_stats
      end

    # 4. Detect existing type mismatches in library
    # Find movies in series-only libraries
    movies_in_series_libs =
      detect_type_mismatches(existing_files, library_path, :movies_in_series)

    # Find TV shows in movies-only libraries
    tv_in_movies_libs =
      detect_type_mismatches(existing_files, library_path, :tv_in_movies)

    cleanup_stats =
      cleanup_stats
      |> Map.put(:movies_in_series_libs, length(movies_in_series_libs))
      |> Map.put(:tv_in_movies_libs, length(tv_in_movies_libs))

    # Log detected mismatches
    if movies_in_series_libs != [] do
      sample_paths =
        Enum.take(movies_in_series_libs, 3)
        |> Enum.map(fn file ->
          # Preload library_path association for path resolution
          file = Mydia.Repo.preload(file, :library_path)
          Mydia.Library.MediaFile.absolute_path(file)
        end)

      Logger.warning("Detected movies in series-only library",
        count: length(movies_in_series_libs),
        library_path: library_path.path,
        sample_paths: sample_paths
      )
    end

    if tv_in_movies_libs != [] do
      sample_paths =
        Enum.take(tv_in_movies_libs, 3)
        |> Enum.map(fn file ->
          # Preload library_path association for path resolution
          file = Mydia.Repo.preload(file, :library_path)
          Mydia.Library.MediaFile.absolute_path(file)
        end)

      Logger.warning("Detected TV shows in movies-only library",
        count: length(tv_in_movies_libs),
        library_path: library_path.path,
        sample_paths: sample_paths
      )
    end

    # 5. Track removed files with invalid paths
    cleanup_stats =
      Map.put(cleanup_stats, :invalid_paths_removed, length(result.changes.deleted_files))

    # Log cleanup summary
    if cleanup_stats.orphaned_files_fixed > 0 or cleanup_stats.tv_orphans_fixed > 0 or
         cleanup_stats.associations_updated > 0 or cleanup_stats.invalid_paths_removed > 0 or
         cleanup_stats.type_mismatches_detected > 0 or cleanup_stats.movies_in_series_libs > 0 or
         cleanup_stats.tv_in_movies_libs > 0 do
      Logger.info("Cleanup summary",
        orphaned_files_fixed: cleanup_stats.orphaned_files_fixed,
        tv_orphans_fixed: cleanup_stats.tv_orphans_fixed,
        associations_updated: cleanup_stats.associations_updated,
        invalid_paths_removed: cleanup_stats.invalid_paths_removed,
        type_mismatches_detected: cleanup_stats.type_mismatches_detected,
        movies_in_series_libs: cleanup_stats.movies_in_series_libs,
        tv_in_movies_libs: cleanup_stats.tv_in_movies_libs
      )
    end

    result = Map.put(result, :cleanup_stats, cleanup_stats)

    # Update library path with success status (skip for runtime paths)
    if updatable_library_path?(library_path) do
      {:ok, _} =
        Settings.update_library_path(library_path, %{
          last_scan_at: DateTime.utc_now(),
          last_scan_status: :success,
          last_scan_error: nil
        })
    end

    # Broadcast scan completed with cleanup stats
    cleanup_stats = Map.get(result, :cleanup_stats, %{})

    Phoenix.PubSub.broadcast(
      Mydia.PubSub,
      "library_scanner",
      {:library_scan_completed,
       %{
         library_path_id: library_path.id,
         type: library_path.type,
         new_files: length(result.changes.new_files),
         modified_files: length(result.changes.modified_files),
         deleted_files: length(result.changes.deleted_files),
         orphaned_files_fixed: Map.get(cleanup_stats, :orphaned_files_fixed, 0),
         tv_orphans_fixed: Map.get(cleanup_stats, :tv_orphans_fixed, 0),
         associations_updated: Map.get(cleanup_stats, :associations_updated, 0),
         invalid_paths_removed: Map.get(cleanup_stats, :invalid_paths_removed, 0),
         type_mismatches_detected: Map.get(cleanup_stats, :type_mismatches_detected, 0),
         movies_in_series_libs: Map.get(cleanup_stats, :movies_in_series_libs, 0),
         tv_in_movies_libs: Map.get(cleanup_stats, :tv_in_movies_libs, 0)
       }}
    )

    {:ok, result}
  rescue
    error ->
      error_message = Exception.format(:error, error, __STACKTRACE__)
      Logger.error("Library scan raised exception", error: error_message)
      handle_scan_error(library_path, error_message)
  end

  # Checks if a library path can be updated in the database.
  # Runtime library paths (from environment variables) can't be updated.
  defp updatable_library_path?(%{id: id}) when is_binary(id) do
    !String.starts_with?(id, "runtime::")
  end

  defp updatable_library_path?(_), do: true

  defp process_media_file(media_file, file_info, metadata_config) do
    Logger.debug("Processing media file for metadata", path: file_info.path)

    # Load library_path to check type restrictions
    media_file = Repo.preload(media_file, :library_path)
    library_path = media_file.library_path

    # Early validation: check if file type is compatible with library type
    # Parse the file using full path to leverage folder structure for TV shows
    # This ensures files in "/media/tv/Show Name/Season XX/" are correctly identified
    parsed = FileParser.parse_with_path(file_info.path)

    case validate_file_type_for_library(parsed.type, library_path, file_info.path) do
      :ok ->
        # Type is compatible, proceed with matching
        match_file_to_existing_items(media_file, file_info, metadata_config, parsed)

      {:error, _reason} = error ->
        # Type mismatch, skip processing
        error
    end
  end

  defp validate_file_type_for_library(file_type, library_path, file_path) do
    cond do
      # Mixed libraries allow both types
      library_path.type == :mixed ->
        :ok

      # Series-only library: only allow TV shows
      library_path.type == :series and file_type == :tv_show ->
        :ok

      library_path.type == :series and file_type == :movie ->
        Logger.info("Skipping movie file in series-only library",
          path: file_path,
          library_path: library_path.path,
          library_type: library_path.type
        )

        {:error, :library_type_mismatch}

      # Movies-only library: only allow movies
      library_path.type == :movies and file_type == :movie ->
        :ok

      library_path.type == :movies and file_type == :tv_show ->
        Logger.info("Skipping TV show file in movies-only library",
          path: file_path,
          library_path: library_path.path,
          library_type: library_path.type
        )

        {:error, :library_type_mismatch}

      # Unknown file type - let it through for now
      file_type == :unknown ->
        Logger.debug("Unknown file type, allowing matching attempt",
          path: file_path
        )

        :ok

      # Any other case
      true ->
        :ok
    end
  end

  defp match_file_to_existing_items(media_file, file_info, metadata_config, _parsed) do
    # Use the library's configured TV metadata source for new matches.
    provider = media_file.library_path && media_file.library_path.tv_metadata_source

    # Try to match the file to metadata
    case MetadataMatcher.match_file(file_info.path,
           config: metadata_config,
           provider: provider
         ) do
      {:ok, match_result} ->
        Logger.info("Matched media file",
          path: file_info.path,
          title: match_result.title,
          provider_id: match_result.provider_id,
          confidence: match_result.match_confidence,
          from_local_db: Map.get(match_result, :from_local_db, false)
        )

        # :local_only is what keeps the scheduled scan from inventing items.
        # An external match is cached as a candidate and the file stays
        # orphaned for the import inbox to offer. See Library.FileIngest.
        case FileIngest.ingest(media_file, match_result,
               policy: :local_only,
               config: metadata_config
             ) do
          {:linked, media_item} ->
            Logger.info("Associated file with existing media item",
              media_item_id: media_item.id,
              title: media_item.title,
              path: file_info.path
            )

            {:ok, :enriched}

          {:candidate, _candidate} ->
            Logger.info("Skipping external match - file will remain orphaned for manual import",
              path: file_info.path,
              title: match_result.title,
              provider_id: match_result.provider_id
            )

            {:error, :no_local_match}

          {:error, {:library_type_mismatch, message}} ->
            Logger.warning("Library type mismatch detected",
              path: file_info.path,
              error: message
            )

            {:error, :library_type_mismatch}

          {:error, _reason} ->
            {:error, :enrichment_failed}

          :no_match ->
            {:error, :no_matches_found}
        end

      {:error, :unknown_media_type} ->
        Logger.debug("Could not determine media type",
          path: file_info.path
        )

        {:error, :unknown_media_type}

      {:error, :no_matches_found} ->
        Logger.info("No metadata matches found - file will remain orphaned",
          path: file_info.path
        )

        {:error, :no_matches_found}

      {:error, :low_confidence_match} ->
        Logger.info("Only low confidence matches found - file will remain orphaned",
          path: file_info.path
        )

        {:error, :low_confidence_match}

      {:error, reason} ->
        Logger.warning("Failed to match media file",
          path: file_info.path,
          reason: reason
        )

        {:error, reason}
    end
  rescue
    error ->
      Logger.error("Exception while processing media file",
        path: file_info.path,
        error: Exception.message(error)
      )

      {:error, :exception}
  end

  # Detects type mismatches in existing files based on library path type
  defp detect_type_mismatches(existing_files, library_path, mismatch_type) do
    # Skip detection for :mixed libraries (they allow both types)
    if library_path.type == :mixed do
      []
    else
      existing_files
      |> Repo.preload([:media_item, :episode])
      |> Enum.filter(fn file ->
        case mismatch_type do
          :movies_in_series ->
            # Movies in a series-only library
            library_path.type == :series and
              not is_nil(file.media_item_id) and
              file.media_item != nil and
              file.media_item.type == "movie"

          :tv_in_movies ->
            # TV shows in a movies-only library
            library_path.type == :movies and
              not is_nil(file.episode_id) and
              file.episode != nil
        end
      end)
    end
  end

  # Attempts to fix an orphaned TV show file by matching it to an episode
  defp fix_orphaned_tv_file(media_file, metadata_config) do
    try do
      # Preload library_path association for path resolution
      media_file = Mydia.Repo.preload(media_file, :library_path)
      path_for_log = Mydia.Library.MediaFile.absolute_path(media_file)

      Logger.debug("Attempting to fix orphaned TV file",
        path: path_for_log,
        media_item_id: media_file.media_item_id
      )

      # Parse using full path to extract season from folder structure if available
      # This handles files where filename doesn't contain season info but folder does
      parsed = FileParser.parse_with_path(path_for_log)

      case parsed do
        %{type: :tv_show, season: season, episodes: episodes}
        when not is_nil(season) and not is_nil(episodes) ->
          # Try to find the episode in the database
          # For multi-episode files, use the first episode
          episode_number = List.first(episodes)

          case Mydia.Media.get_episode_by_number(media_file.media_item_id, season, episode_number) do
            nil ->
              # Episode doesn't exist yet, try to fetch it from TMDB
              Logger.info("Episode not found, attempting to fetch from provider",
                media_item_id: media_file.media_item_id,
                season: season,
                episode: episode_number
              )

              # Fetch the media item to get provider ID
              media_item = Mydia.Media.get_media_item!(media_file.media_item_id)

              # Prefer tvdb_id for TV shows, fall back to tmdb_id
              {provider_id, has_tvdb} =
                cond do
                  media_item.tvdb_id -> {media_item.tvdb_id, true}
                  media_item.tmdb_id -> {media_item.tmdb_id, false}
                  true -> {nil, false}
                end

              if provider_id do
                # Pass tvdb_season_id when using TVDB so the relay routes correctly
                fetch_opts =
                  if has_tvdb do
                    # For TVDB we need the season's TVDB ID for proper routing
                    # We don't have it here, so pass empty opts (relay will use series ID + season number)
                    []
                  else
                    []
                  end

                # Fetch season data from the appropriate provider
                case Metadata.fetch_season(
                       metadata_config,
                       to_string(provider_id),
                       season,
                       fetch_opts
                     ) do
                  {:ok, season_data} ->
                    # Create episodes for this season
                    create_episodes_from_season(media_item, season_data)

                    # Try to find the episode again
                    case Mydia.Media.get_episode_by_number(
                           media_file.media_item_id,
                           season,
                           episode_number
                         ) do
                      nil ->
                        Logger.warning("Episode still not found after provider fetch",
                          media_item_id: media_file.media_item_id,
                          season: season,
                          episode: episode_number
                        )

                        false

                      episode ->
                        associate_file_with_episode(media_file, episode)
                    end

                  {:error, reason} ->
                    Logger.warning("Failed to fetch season from provider",
                      media_item_id: media_file.media_item_id,
                      season: season,
                      reason: reason
                    )

                    false
                end
              else
                Logger.warning("Media item has no provider ID, cannot fetch episodes",
                  media_item_id: media_file.media_item_id
                )

                false
              end

            episode ->
              # Episode exists, associate the file with it
              associate_file_with_episode(media_file, episode)
          end

        _ ->
          Logger.debug("Could not parse season/episode info from filename",
            path: path_for_log
          )

          false
      end
    rescue
      error ->
        # Recalculate path for error logging if media_file hasn't been preloaded yet
        media_file = Mydia.Repo.preload(media_file, :library_path, force: true)
        error_path = Mydia.Library.MediaFile.absolute_path(media_file)

        Logger.error("Exception while fixing orphaned TV file",
          path: error_path,
          error: Exception.message(error)
        )

        false
    end
  end

  # Re-validates a TV file's episode association by re-parsing the filename
  defp revalidate_tv_file_association(media_file) do
    # Preload library_path for path resolution
    media_file = Mydia.Repo.preload(media_file, :library_path)
    full_path = Mydia.Library.MediaFile.absolute_path(media_file)

    # Parse using full path to extract season from folder structure if available
    parsed = FileParser.parse_with_path(full_path)

    case parsed do
      %{type: :tv_show, season: season, episodes: episodes}
      when not is_nil(season) and not is_nil(episodes) ->
        # Get the first episode number (for multi-episode files)
        episode_number = List.first(episodes)

        # Check if this matches the current association
        if media_file.episode.season_number != season or
             media_file.episode.episode_number != episode_number do
          Logger.info("File association mismatch detected",
            path: full_path,
            current_season: media_file.episode.season_number,
            current_episode: media_file.episode.episode_number,
            parsed_season: season,
            parsed_episode: episode_number
          )

          # Try to find the correct episode
          case Mydia.Media.get_episode_by_number(
                 media_file.episode.media_item_id,
                 season,
                 episode_number
               ) do
            nil ->
              Logger.warning("Correct episode not found, keeping current association",
                media_item_id: media_file.episode.media_item_id,
                season: season,
                episode: episode_number
              )

              false

            new_episode ->
              # Update the association
              case Library.update_media_file(media_file, %{episode_id: new_episode.id}) do
                {:ok, _updated_file} ->
                  Logger.info("Updated file association",
                    path: full_path,
                    old_episode:
                      "S#{media_file.episode.season_number}E#{media_file.episode.episode_number}",
                    new_episode: "S#{new_episode.season_number}E#{new_episode.episode_number}"
                  )

                  true

                {:error, reason} ->
                  Logger.error("Failed to update file association",
                    path: full_path,
                    reason: reason
                  )

                  false
              end
          end
        else
          # Association is correct
          false
        end

      _ ->
        # Could not parse or not a TV show file
        false
    end
  rescue
    error ->
      # Preload library_path association for path resolution in rescue
      media_file = Mydia.Repo.preload(media_file, :library_path)
      path_for_log = Mydia.Library.MediaFile.absolute_path(media_file)

      Logger.error("Exception while revalidating file association",
        path: path_for_log,
        error: Exception.message(error)
      )

      false
  end

  # Associates a media file with an episode
  # For TV shows, files should have episode_id set, not media_item_id
  # So we need to clear media_item_id when setting episode_id
  defp associate_file_with_episode(media_file, episode) do
    try do
      # Preload library_path association for path resolution
      media_file = Mydia.Repo.preload(media_file, :library_path)
      path_for_log = Mydia.Library.MediaFile.absolute_path(media_file)

      case Library.update_media_file(media_file, %{episode_id: episode.id, media_item_id: nil}) do
        {:ok, _updated_file} ->
          Logger.info("Associated file with episode",
            path: path_for_log,
            episode: "S#{episode.season_number}E#{episode.episode_number}"
          )

          true

        {:error, reason} ->
          Logger.error("Failed to associate file with episode",
            path: path_for_log,
            reason: inspect(reason)
          )

          false
      end
    rescue
      error ->
        # Recalculate path for error logging
        media_file = Mydia.Repo.preload(media_file, :library_path, force: true)
        error_path = Mydia.Library.MediaFile.absolute_path(media_file)

        Logger.error("Exception while associating file with episode",
          path: error_path,
          error: Exception.message(error)
        )

        false
    end
  end

  # Creates/updates episodes from season data using the consolidated function
  defp create_episodes_from_season(media_item, season_data) do
    {:ok, count} =
      Mydia.Media.upsert_episodes_from_season(media_item, season_data,
        monitor_new?:
          Mydia.Media.should_monitor_new_episode?(media_item, season_data.season_number)
      )

    Logger.debug("Upserted #{count} episodes from season data",
      media_item_id: media_item.id,
      season: season_data.season_number
    )
  rescue
    error ->
      Logger.error("Exception while creating episodes from season data",
        media_item_id: media_item.id,
        error: Exception.message(error)
      )
  end
end
