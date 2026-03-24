defmodule Mydia.Jobs.LibraryScanner do
  @moduledoc """
  Background job for scanning the media library.

  This job:
  - Scans configured library paths for media files
  - Detects new, modified, and deleted files
  - Updates the database with file information
  - Tracks scan status and errors

  For scheduled "scan all" runs, a random delay (0-30 minutes) is applied
  to spread load across self-hosted instances hitting the metadata relay.
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3

  require Logger
  alias Mydia.{Library, Settings, Repo, Metadata}

  # Random delay range for scheduled scan_all (0-30 minutes in ms)
  @max_startup_delay_ms 30 * 60 * 1000

  alias Mydia.Library.{
    MetadataMatcher,
    MetadataEnricher,
    MusicScanner,
    BookScanner,
    AdultScanner,
    SampleDetector
  }

  alias Mydia.Library.FileParser.V2, as: FileParser

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Oban job args use string keys (JSON) - optional field with default
    library_path_id = args["library_path_id"]
    library_type = args["library_type"]

    # Add random delay for scheduled "scan all" runs to spread load across instances
    # Skip delay for manual triggers (skip_delay: true) or specific library scans
    if is_nil(library_path_id) and is_nil(library_type) and not Map.get(args, "skip_delay", false) do
      delay_ms = :rand.uniform(@max_startup_delay_ms)
      delay_minutes = Float.round(delay_ms / 60_000, 1)

      Logger.info("Library scan scheduled, waiting #{delay_minutes} minutes before starting")
      Process.sleep(delay_ms)
    end

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
      {:ok, result} ->
        Logger.info("Library scan completed successfully",
          library_path_id: library_path_id,
          new_files: length(result.changes.new_files),
          modified_files: length(result.changes.modified_files),
          deleted_files: length(result.changes.deleted_files)
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
  end

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
    if length(files_needing_thumbnails) > 0 do
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

    # Process new files: match → create with parent → enrich
    # Each file is matched using the existing MetadataMatcher pipeline before creation,
    # ensuring every MediaFile has a media_item_id from the start.
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

        Enum.map(batch, fn file_info ->
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
              # No existing file — create new, but only if we can resolve a parent
              create_matched_media_file(file_info, relative_path, library_path)
          end
        end)
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
          {:ok, _} = Library.trash_media_file(media_file)

          # Preload library_path association for path resolution
          media_file = Mydia.Repo.preload(media_file, :library_path)
          absolute_path = Mydia.Library.MediaFile.absolute_path(media_file)

          Logger.debug("Trashed media file record", path: absolute_path)
        end)
      end)
    end)

    # Matching and enrichment already happened during file creation above.
    # Build result for downstream cleanup code.
    result = %{changes: changes, scan_result: scan_result, new_media_files: new_media_files}

    # Count type mismatches from the new file results
    type_mismatch_count =
      Enum.count(new_media_files, &match?({:error, :library_type_mismatch, _}, &1))

    # Initialize tracking for robust cleanup operations
    cleanup_stats = %{
      associations_updated: 0,
      invalid_paths_removed: 0,
      type_mismatches_detected: type_mismatch_count,
      movies_in_series_libs: 0,
      tv_in_movies_libs: 0
    }

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
    if cleanup_stats.associations_updated > 0 or cleanup_stats.invalid_paths_removed > 0 or
         cleanup_stats.type_mismatches_detected > 0 or cleanup_stats.movies_in_series_libs > 0 or
         cleanup_stats.tv_in_movies_libs > 0 do
      Logger.info("Cleanup summary",
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

  # Creates a new media file only after successfully matching it to a local MediaItem.
  # Uses the existing MetadataMatcher + MetadataEnricher pipeline — no duplicated logic.
  # Returns {:ok, media_file, file_info} | {:error, reason, file_info} | {:skipped, file_info}
  defp create_matched_media_file(file_info, relative_path, library_path) do
    metadata_config = Metadata.default_relay_config()
    parsed = FileParser.parse_with_path(file_info.path)

    with :ok <- validate_file_type_for_library(parsed.type, library_path, file_info.path),
         {:ok, match_result} <- match_to_local_item(file_info.path, metadata_config),
         {:ok, media_item} <- enrich_match(match_result, metadata_config, file_info.path) do
      # Create file with media_item_id set
      case Library.create_scanned_media_file(%{
             library_path_id: library_path.id,
             relative_path: relative_path,
             media_item_id: media_item.id,
             size: file_info.size,
             verified_at: DateTime.utc_now()
           }) do
        {:ok, media_file} ->
          Logger.info("Created matched media file",
            path: file_info.path,
            media_item: media_item.title,
            media_item_id: media_item.id
          )

          # For TV shows, associate with episode using existing enricher
          if media_item.type == "tv_show" and Map.has_key?(match_result, :parsed_info) do
            MetadataEnricher.enrich(
              Map.put(match_result, :media_file_id, media_file.id),
              config: metadata_config,
              fetch_episodes: true
            )
          end

          {:ok, media_file, file_info}

        {:error, changeset} ->
          Logger.error("Failed to create media file",
            path: file_info.path,
            errors: inspect(changeset.errors)
          )

          {:error, file_info}
      end
    else
      {:error, :library_type_mismatch} ->
        {:error, :library_type_mismatch, file_info}

      {:skip, _reason} ->
        {:skipped, file_info}
    end
  rescue
    error ->
      Logger.error("Exception creating matched media file",
        path: file_info.path,
        error: Exception.message(error)
      )

      {:error, file_info}
  end

  # Matches a file to a local DB item using the existing MetadataMatcher pipeline.
  # Returns {:ok, match_result} for local matches, {:skip, reason} otherwise.
  defp match_to_local_item(file_path, metadata_config) do
    case MetadataMatcher.match_file(file_path, config: metadata_config) do
      {:ok, match_result} ->
        if Map.get(match_result, :from_local_db, false) do
          {:ok, match_result}
        else
          Logger.info("Skipping file (external match only, use Import page)",
            path: file_path,
            title: match_result.title
          )

          {:skip, :external_match_only}
        end

      {:error, reason} ->
        Logger.info("Skipping unmatched file", path: file_path, reason: reason)
        {:skip, reason}
    end
  end

  # Enriches a match result to get/create the MediaItem.
  defp enrich_match(match_result, metadata_config, file_path) do
    case MetadataEnricher.enrich(match_result, config: metadata_config) do
      {:ok, media_item} ->
        {:ok, media_item}

      {:error, {:library_type_mismatch, _}} ->
        {:error, :library_type_mismatch}

      {:error, reason} ->
        Logger.warning("Failed to enrich — skipping file",
          path: file_path,
          reason: reason
        )

        {:skip, reason}
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
end
