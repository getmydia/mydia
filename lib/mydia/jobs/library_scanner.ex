defmodule Mydia.Jobs.LibraryScanner do
  @moduledoc """
  Background job for scanning the media library.

  This job:
  - Scans configured library paths for media files
  - Detects new, modified, and deleted files
  - Updates the database with file information
  - Tracks scan status and errors
  """

  use Oban.Worker,
    queue: :media,
    max_attempts: 3

  require Logger
  alias Mydia.{Library, Settings, Repo}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    library_path_id = Map.get(args, "library_path_id")

    case library_path_id do
      nil ->
        scan_all_libraries()

      id ->
        scan_single_library(id)
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

    # Mark scan as in progress (skip for runtime paths)
    if updatable_library_path?(library_path) do
      {:ok, _} =
        Settings.update_library_path(library_path, %{
          last_scan_status: :in_progress,
          last_scan_error: nil
        })
    end

    # Perform the file system scan
    progress_callback = fn count ->
      Logger.debug("Scan progress", library_path_id: library_path.id, files_scanned: count)
    end

    scan_result =
      case Library.Scanner.scan(library_path.path, progress_callback: progress_callback) do
        {:ok, result} -> result
        {:error, reason} -> raise "Scan failed: #{inspect(reason)}"
      end

    # Get existing files from database
    existing_files = Library.list_media_files()

    # Detect changes
    changes = Library.Scanner.detect_changes(scan_result, existing_files)

    # Process changes in a transaction
    Repo.transaction(fn ->
      # Add new files
      Enum.each(changes.new_files, fn file_info ->
        {:ok, _} =
          Library.create_media_file(%{
            path: file_info.path,
            size: file_info.size,
            quality: detect_quality(file_info.filename),
            format: String.trim_leading(file_info.extension, "."),
            verified_at: DateTime.utc_now()
          })

        Logger.debug("Added new media file", path: file_info.path)
      end)

      # Update modified files
      Enum.each(changes.modified_files, fn file_info ->
        case Library.get_media_file_by_path(file_info.path) do
          nil ->
            Logger.warning("Modified file not found in database", path: file_info.path)

          media_file ->
            {:ok, _} =
              Library.update_media_file(media_file, %{
                size: file_info.size,
                verified_at: DateTime.utc_now()
              })

            Logger.debug("Updated media file", path: file_info.path)
        end
      end)

      # Mark deleted files
      Enum.each(changes.deleted_files, fn media_file ->
        {:ok, _} = Library.delete_media_file(media_file)
        Logger.debug("Deleted media file record", path: media_file.path)
      end)

      %{changes: changes, scan_result: scan_result}
    end)
    |> case do
      {:ok, result} ->
        # Update library path with success status (skip for runtime paths)
        if updatable_library_path?(library_path) do
          {:ok, _} =
            Settings.update_library_path(library_path, %{
              last_scan_at: DateTime.utc_now(),
              last_scan_status: :success,
              last_scan_error: nil
            })
        end

        {:ok, result}

      {:error, reason} ->
        error_message = "Transaction failed: #{inspect(reason)}"

        # Update library path with error status (skip for runtime paths)
        if updatable_library_path?(library_path) do
          {:ok, _} =
            Settings.update_library_path(library_path, %{
              last_scan_at: DateTime.utc_now(),
              last_scan_status: :failed,
              last_scan_error: error_message
            })
        end

        {:error, reason}
    end
  rescue
    error ->
      error_message = Exception.format(:error, error, __STACKTRACE__)
      Logger.error("Library scan raised exception", error: error_message)

      # Update library path with error status (skip for runtime paths)
      if updatable_library_path?(library_path) do
        {:ok, _} =
          Settings.update_library_path(library_path, %{
            last_scan_at: DateTime.utc_now(),
            last_scan_status: :failed,
            last_scan_error: error_message
          })
      end

      {:error, error}
  end

  # Checks if a library path can be updated in the database.
  # Runtime library paths (from environment variables) can't be updated.
  defp updatable_library_path?(%{id: id}) when is_binary(id) do
    !String.starts_with?(id, "runtime::")
  end

  defp updatable_library_path?(_), do: true

  # Simple quality detection based on filename patterns
  defp detect_quality(filename) do
    filename_lower = String.downcase(filename)

    cond do
      String.contains?(filename_lower, ["2160p", "4k", "uhd"]) -> "2160p"
      String.contains?(filename_lower, ["1080p", "fhd"]) -> "1080p"
      String.contains?(filename_lower, ["720p", "hd"]) -> "720p"
      String.contains?(filename_lower, ["480p", "sd"]) -> "480p"
      true -> "Unknown"
    end
  end
end
