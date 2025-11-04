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

  @video_extensions ~w(.mkv .mp4 .avi .mov .wmv .flv .webm .m4v .mpg .mpeg .m2ts .ts)

  @doc """
  Scans a directory for media files.

  Returns `{:ok, scan_result}` with details about the scan, or `{:error, reason}`.

  ## Options
    - `:recursive` - Whether to scan subdirectories (default: true)
    - `:video_extensions` - List of video file extensions to detect (default: common formats)
    - `:progress_callback` - Function called with progress updates (file_count)

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

    Logger.info("Starting library scan", directory: directory_path, recursive: recursive)

    case validate_directory(directory_path) do
      :ok ->
        result = do_scan(directory_path, recursive, extensions, progress_callback)

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
  """
  def detect_changes(scan_result, existing_files) do
    scanned_paths = MapSet.new(scan_result.files, & &1.path)
    existing_paths = MapSet.new(existing_files, & &1.path)

    new_paths = MapSet.difference(scanned_paths, existing_paths)
    deleted_paths = MapSet.difference(existing_paths, scanned_paths)

    new_files =
      Enum.filter(scan_result.files, fn file ->
        MapSet.member?(new_paths, file.path)
      end)

    deleted_files =
      Enum.filter(existing_files, fn file ->
        MapSet.member?(deleted_paths, file.path)
      end)

    # Check for modifications among files that exist in both
    existing_by_path = Map.new(existing_files, &{&1.path, &1})

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

  defp do_scan(directory_path, recursive, extensions, progress_callback) do
    initial_state = %{
      files: [],
      errors: [],
      file_count: 0,
      total_size: 0
    }

    result =
      walk_directory(directory_path, recursive, extensions, progress_callback, initial_state)

    %{
      files: Enum.reverse(result.files),
      total_count: result.file_count,
      total_size: result.total_size,
      errors: Enum.reverse(result.errors)
    }
  end

  defp walk_directory(path, recursive, extensions, progress_callback, state) do
    case File.ls(path) do
      {:ok, entries} ->
        Enum.reduce(entries, state, fn entry, acc ->
          full_path = Path.join(path, entry)
          process_entry(full_path, recursive, extensions, progress_callback, acc)
        end)

      {:error, reason} ->
        error = %{path: path, reason: reason, type: :directory_read_error}
        Logger.warning("Failed to read directory", path: path, reason: reason)
        %{state | errors: [error | state.errors]}
    end
  end

  defp process_entry(path, recursive, extensions, progress_callback, state) do
    # Use lstat to detect symlinks without following them
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        if recursive do
          walk_directory(path, recursive, extensions, progress_callback, state)
        else
          state
        end

      {:ok, %File.Stat{type: :symlink}} ->
        # Follow symlink to check what it points to
        case File.stat(path) do
          {:ok, %File.Stat{type: :directory}} when recursive ->
            walk_directory(path, recursive, extensions, progress_callback, state)

          {:ok, %File.Stat{type: :regular}} ->
            process_file(path, extensions, progress_callback, state)

          {:ok, _} ->
            state

          {:error, reason} ->
            error = %{path: path, reason: reason, type: :symlink_resolution_error}
            Logger.debug("Failed to resolve symlink", path: path, reason: reason)
            %{state | errors: [error | state.errors]}
        end

      {:ok, %File.Stat{type: :regular}} ->
        process_file(path, extensions, progress_callback, state)

      {:ok, _} ->
        # Other file types (device, pipe, etc.) - skip
        state

      {:error, reason} ->
        error = %{path: path, reason: reason, type: :stat_error}
        Logger.debug("Failed to stat file", path: path, reason: reason)
        %{state | errors: [error | state.errors]}
    end
  end

  defp process_file(path, extensions, progress_callback, state) do
    if video_file?(path, extensions) do
      case extract_file_metadata(path) do
        {:ok, file_info} ->
          new_count = state.file_count + 1

          # Report progress every 100 files
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

  defp file_modified?(scanned, existing) do
    scanned.size != existing.size ||
      DateTime.compare(
        scanned.modified_at,
        Map.get(existing, :verified_at, existing.updated_at)
      ) == :gt
  end
end
