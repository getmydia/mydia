defmodule Mydia.Library.Scanner do
  @moduledoc """
  Scans library directories for media files.

  This module handles:
  - Recursive directory traversal
  - Video file detection by extension
  - File metadata extraction
  - Error handling for file system issues
  - Progress tracking for large directories
  """

  require Logger

  alias Mydia.Library.TrashStore

  @video_extensions ~w(.mkv .mp4 .avi .mov .wmv .flv .webm .m4v .mpg .mpeg .m2ts .ts)

  @doc """
  Returns file extensions for the given library type.
  """
  def extensions_for_library_type(:movies), do: @video_extensions
  def extensions_for_library_type(:series), do: @video_extensions
  def extensions_for_library_type(:mixed), do: @video_extensions
  def extensions_for_library_type(_), do: @video_extensions

  @doc """
  Scans a directory for media files.

  Returns `{:ok, scan_result}` with details about the scan, or `{:error, reason}`.

  ## Options
    - `:recursive` - Whether to scan subdirectories (default: true)
    - `:video_extensions` - List of video file extensions to detect (default: common formats)
    - `:progress_callback` - Function called with progress updates (file_count)
    - `:path_callback` - Function called with each directory entered and each video file found

  ## Examples

      iex> Scanner.scan("/media/movies")
      {:ok, %{
        files: [%{path: "/media/movies/movie.mkv", size: 1024, ...}],
        total_count: 1,
        total_size: 1024,
        errors: []
      }}
  """
  def scan(directory_path, opts \\ []) do
    recursive = Keyword.get(opts, :recursive, true)
    extensions = Keyword.get(opts, :video_extensions, @video_extensions)
    progress_callback = Keyword.get(opts, :progress_callback)
    path_callback = Keyword.get(opts, :path_callback)

    Logger.info("Starting library scan", directory: directory_path, recursive: recursive)

    case validate_directory(directory_path) do
      :ok ->
        result = do_scan(directory_path, recursive, extensions, progress_callback, path_callback)

        Logger.info("Library scan completed",
          directory: directory_path,
          files_found: length(result.files),
          errors: length(result.errors)
        )

        {:ok, result}

      {:error, reason} = error ->
        Logger.error("Directory validation failed", directory: directory_path, reason: reason)
        error
    end
  end

  @doc """
  Scans multiple directories and returns combined results.
  """
  def scan_multiple(directories, opts \\ []) do
    results =
      Enum.map(directories, fn dir ->
        case scan(dir, opts) do
          {:ok, result} -> Map.put(result, :directory, dir)
          {:error, reason} -> %{directory: dir, error: reason, files: [], errors: []}
        end
      end)

    combined = %{
      scans: results,
      files: Enum.flat_map(results, & &1.files),
      total_count: Enum.sum(Enum.map(results, &length(&1.files))),
      total_size: Enum.sum(Enum.map(results, &Map.get(&1, :total_size, 0))),
      errors: Enum.flat_map(results, &(&1[:errors] || []))
    }

    {:ok, combined}
  end

  @doc """
  Detects changes between current file system state and database records.

  Returns a map with:
    - `:new_files` - Files found on disk but not in database
    - `:modified_files` - Files that have changed (size or modified time)
    - `:deleted_files` - Files in database but not found on disk

  When library_path is provided, compares files using relative paths.
  """
  def detect_changes(scan_result, existing_files, library_path \\ nil) do
    # Convert scanned files to use absolute paths for comparison
    scanned_paths = MapSet.new(scan_result.files, & &1.path)

    # Convert existing files' relative paths to absolute paths for comparison
    existing_paths =
      if library_path do
        MapSet.new(existing_files, fn file ->
          Path.join(library_path.path, file.relative_path)
        end)
      else
        # Fallback for legacy code that still uses absolute paths
        MapSet.new(existing_files, & &1.path)
      end

    new_paths = MapSet.difference(scanned_paths, existing_paths)
    deleted_paths = MapSet.difference(existing_paths, scanned_paths)

    new_files =
      Enum.filter(scan_result.files, fn file ->
        MapSet.member?(new_paths, file.path)
      end)

    deleted_files =
      Enum.filter(existing_files, fn file ->
        absolute_path =
          if library_path do
            Path.join(library_path.path, file.relative_path)
          else
            file.path
          end

        MapSet.member?(deleted_paths, absolute_path)
      end)

    # Check for modifications among files that exist in both
    existing_by_path =
      if library_path do
        Map.new(existing_files, fn file ->
          {Path.join(library_path.path, file.relative_path), file}
        end)
      else
        Map.new(existing_files, &{&1.path, &1})
      end

    modified_files =
      scan_result.files
      |> Enum.reject(&MapSet.member?(new_paths, &1.path))
      |> Enum.filter(fn scanned ->
        case Map.get(existing_by_path, scanned.path) do
          nil ->
            false

          existing ->
            file_modified?(scanned, existing)
        end
      end)

    %{
      new_files: new_files,
      modified_files: modified_files,
      deleted_files: deleted_files
    }
  end

  ## Private Functions

  defp validate_directory(path) do
    cond do
      not File.exists?(path) ->
        {:error, :not_found}

      not File.dir?(path) ->
        {:error, :not_directory}

      true ->
        # Test read permissions
        case File.ls(path) do
          {:ok, _} -> :ok
          {:error, :eacces} -> {:error, :permission_denied}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp do_scan(directory_path, recursive, extensions, progress_callback, path_callback) do
    initial_state = %{
      files: [],
      errors: [],
      file_count: 0,
      total_size: 0
    }

    result =
      walk_directory(
        directory_path,
        recursive,
        extensions,
        progress_callback,
        path_callback,
        initial_state
      )

    %{
      files: Enum.reverse(result.files),
      total_count: result.file_count,
      total_size: result.total_size,
      errors: Enum.reverse(result.errors)
    }
  end

  defp walk_directory(path, recursive, extensions, progress_callback, path_callback, state) do
    if path_callback, do: path_callback.(path)

    case File.ls(path) do
      {:ok, entries} ->
        Enum.reduce(entries, state, fn entry, acc ->
          full_path = Path.join(path, entry)
          process_entry(full_path, recursive, extensions, progress_callback, path_callback, acc)
        end)

      {:error, reason} ->
        error = %{path: path, reason: reason, type: :directory_read_error}
        Logger.warning("Failed to read directory", path: path, reason: reason)
        %{state | errors: [error | state.errors]}
    end
  end

  defp process_entry(path, recursive, extensions, progress_callback, path_callback, state) do
    # Use lstat to detect symlinks without following them
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        if recursive and not trash_directory?(path) do
          walk_directory(path, recursive, extensions, progress_callback, path_callback, state)
        else
          state
        end

      {:ok, %File.Stat{type: :symlink}} ->
        # Follow symlink to check what it points to
        case File.stat(path) do
          {:ok, %File.Stat{type: :directory}} when recursive ->
            if trash_directory?(path) do
              state
            else
              walk_directory(path, recursive, extensions, progress_callback, path_callback, state)
            end

          {:ok, %File.Stat{type: :regular}} ->
            process_file(path, extensions, progress_callback, path_callback, state)

          {:ok, _} ->
            state

          {:error, reason} ->
            error = %{path: path, reason: reason, type: :symlink_resolution_error}
            Logger.debug("Failed to resolve symlink", path: path, reason: reason)
            %{state | errors: [error | state.errors]}
        end

      {:ok, %File.Stat{type: :regular}} ->
        process_file(path, extensions, progress_callback, path_callback, state)

      {:ok, _} ->
        # Other file types (device, pipe, etc.) - skip
        state

      {:error, reason} ->
        error = %{path: path, reason: reason, type: :stat_error}
        Logger.debug("Failed to stat file", path: path, reason: reason)
        %{state | errors: [error | state.errors]}
    end
  end

  # Trashed media is moved *outside* every library path by default (see
  # Mydia.Library.TrashStore), so this normally never fires. It is the second
  # line of defence for nested library layouts, where one library path can
  # contain the parent directory another library trashes into: a scan that
  # walked the trash would classify every trashed file as new and restore its
  # row, undoing the trash.
  defp trash_directory?(path), do: Path.basename(path) == TrashStore.dir_name()

  defp process_file(path, extensions, progress_callback, path_callback, state) do
    if video_file?(path, extensions) do
      case extract_file_metadata(path) do
        {:ok, file_info} ->
          new_count = state.file_count + 1

          # Report the file and, every 100 files, a count.
          if path_callback, do: path_callback.(path)

          if progress_callback && rem(new_count, 100) == 0 do
            progress_callback.(new_count)
          end

          %{
            state
            | files: [file_info | state.files],
              file_count: new_count,
              total_size: state.total_size + file_info.size
          }

        {:error, reason} ->
          error = %{path: path, reason: reason, type: :file_metadata_error}
          Logger.debug("Failed to extract metadata", path: path, reason: reason)
          %{state | errors: [error | state.errors]}
      end
    else
      state
    end
  end

  defp video_file?(path, extensions) do
    ext = Path.extname(path) |> String.downcase()
    Enum.member?(extensions, ext)
  end

  defp extract_file_metadata(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{size: size, mtime: mtime}} ->
        {:ok,
         %{
           path: path,
           size: size,
           modified_at: DateTime.from_unix!(mtime),
           filename: Path.basename(path),
           directory: Path.dirname(path),
           extension: Path.extname(path) |> String.downcase()
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Determines if a scanned file has been modified compared to the database record.
  #
  # A file is considered modified if:
  # - The size has changed, OR
  # - The file's modification time is newer than the last verification time
  #
  # For timestamp comparison, we use `verified_at` if available (when the file was last
  # verified during a scan), falling back to `updated_at` if the file hasn't been verified yet.
  #
  # Note: We use Map.get/2 with || operator because Map.get/3 returns the actual value even
  # if it's nil, not the default. The || operator properly falls back to updated_at when
  # verified_at is nil or missing.
  defp file_modified?(scanned, existing) do
    # Safely get verified_at, falling back to updated_at if verified_at is nil or missing
    reference_time = Map.get(existing, :verified_at) || Map.get(existing, :updated_at)

    scanned.size != existing.size ||
      (not is_nil(reference_time) &&
         DateTime.compare(scanned.modified_at, reference_time) == :gt)
  end
end
