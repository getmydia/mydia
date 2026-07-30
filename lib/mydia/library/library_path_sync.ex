defmodule Mydia.Library.LibraryPathSync do
  @moduledoc """
  Shared module for syncing library paths and populating relative paths in media files.

  Used by both:
  - One-time migration (populate_media_file_relative_paths.exs)
  - Startup task (StartupSync)

  ## Key Responsibilities

  1. **Sync Runtime Library Paths to Database**
     - Reads library paths from runtime config (env vars, YAML)
     - Upserts them to database using path as unique key
     - Ensures database is consistent with current configuration

  2. **Match Files to Library Paths**
     - Uses longest prefix matching to find correct library path for each file
     - Handles edge cases (orphaned files, files outside library paths)

  3. **Calculate Relative Paths**
     - Converts absolute paths to relative paths
     - Stores library_path_id foreign key reference
  """

  require Logger
  import Ecto.Query
  alias Mydia.Repo
  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath
  alias Mydia.Library.MediaFile

  @doc """
  Syncs runtime library paths to the database.

  Reads library paths from `Settings.get_runtime_library_paths/0` and ensures
  they exist in the database. Runtime paths are upserted using the path field
  as the unique key.

  Also disables library paths that were previously created from environment
  variables but are no longer present in the config (sets monitored: false).

  This function is idempotent and safe to call multiple times.

  Returns {:ok, stats} where stats contains:
  - synced: Number of paths synced from env
  - disabled: Number of paths disabled (removed from env)
  """
  def sync_from_runtime_config do
    runtime_paths = Settings.get_runtime_library_paths()

    runtime_path_strings =
      runtime_paths
      |> Enum.filter(&is_runtime_path?/1)
      |> Enum.map(& &1.path)
      |> MapSet.new()

    # Sync runtime paths to database
    synced_count = upsert_runtime_paths(runtime_paths)

    # Disable env-sourced paths that are no longer in config
    disabled_count = disable_removed_env_paths(runtime_path_strings)

    {:ok, %{synced: synced_count, disabled: disabled_count}}
  end

  @doc """
  Upserts the given runtime library paths into the database.

  Exposed so the scan_interval layering can be tested without mutating global env.
  `sync_from_runtime_config/0` calls this with the paths it reads from config.
  """
  @spec upsert_runtime_paths([LibraryPath.t()]) :: non_neg_integer()
  def upsert_runtime_paths(runtime_paths) do
    runtime_paths
    |> Enum.filter(&is_runtime_path?/1)
    |> Enum.reduce(0, fn runtime_path, count ->
      case upsert_library_path(runtime_path) do
        {:ok, _} ->
          count + 1

        {:error, changeset} ->
          # A silently dropped path is how a library disappears without a trace.
          Logger.warning("Failed to sync library path from config: #{runtime_path.path}",
            errors: inspect(changeset.errors)
          )

          count
      end
    end)
  end

  @doc """
  Populates library_path_id and relative_path for all media files.

  Processes all media files in the database:
  1. Finds matching library path (longest prefix)
  2. Calculates relative path
  3. Updates media_files record

  Orphaned files (no matching library path) are logged but not updated.

  Returns {:ok, stats} where stats contains:
  - updated: Number of files successfully updated
  - orphaned: Number of files with no matching library path
  - failed: Number of files that failed to update
  """
  def populate_all_media_files do
    # Get all library paths once (includes both database and runtime)
    all_library_paths = Settings.list_library_paths()

    # Get all media files that need updating (missing library_path_id or relative_path)
    media_files =
      MediaFile
      |> where([mf], is_nil(mf.library_path_id) or is_nil(mf.relative_path))
      |> Repo.all()

    stats = %{updated: 0, orphaned: 0, failed: 0, skipped: 0}

    # Count already-populated files for reporting
    already_populated_count =
      MediaFile
      |> where([mf], not is_nil(mf.library_path_id) and not is_nil(mf.relative_path))
      |> Repo.aggregate(:count)

    if already_populated_count > 0 do
      Logger.info("Skipping #{already_populated_count} files that already have relative paths")
    end

    stats =
      Enum.reduce(media_files, stats, fn media_file, acc ->
        case populate_media_file(media_file, all_library_paths) do
          {:ok, :updated} ->
            %{acc | updated: acc.updated + 1}

          {:ok, :skipped} ->
            %{acc | skipped: acc.skipped + 1}

          {:ok, :orphaned} ->
            file_path = media_file.path || media_file.relative_path || media_file.id
            Logger.info("Orphaned file (no matching library path): #{file_path}")
            %{acc | orphaned: acc.orphaned + 1}

          {:error, reason} ->
            file_path = media_file.path || media_file.relative_path || media_file.id
            Logger.warning("Failed to update media file #{file_path}: #{inspect(reason)}")
            %{acc | failed: acc.failed + 1}
        end
      end)

    {:ok, Map.put(stats, :skipped, stats.skipped + already_populated_count)}
  end

  @doc """
  Counts media files that need library_path_id or relative_path populated.

  Used by startup task to determine if any work is needed.
  """
  def count_files_needing_fix do
    MediaFile
    |> where([mf], is_nil(mf.library_path_id) or is_nil(mf.relative_path))
    |> Repo.aggregate(:count)
  end

  ## Private Functions

  # Checks if a library path is from runtime config (not database)
  defp is_runtime_path?(%LibraryPath{id: id}) when is_binary(id) do
    String.starts_with?(id, "runtime::")
  end

  defp is_runtime_path?(_), do: false

  # Upserts a runtime library path to the database
  defp upsert_library_path(%LibraryPath{} = runtime_path) do
    existing = Repo.get_by(LibraryPath, path: runtime_path.path)

    attrs = %{
      type: runtime_path.type,
      monitored: runtime_path.monitored,
      quality_profile_id: runtime_path.quality_profile_id,
      from_env: true,
      disabled: false
    }

    # Only let the config source drive scan_interval when it actually set one.
    # LIBRARY_PATH_<N>_SCAN_INTERVAL is parsed with put_if_present, so an unset
    # var arrives here as nil. Writing that nil would reset the admin UI's choice
    # on every boot, so an unset interval leaves the DB overlay untouched.
    attrs =
      if is_nil(runtime_path.scan_interval) do
        attrs
      else
        Map.put(attrs, :scan_interval, runtime_path.scan_interval)
      end

    if existing do
      existing |> LibraryPath.changeset(attrs) |> Repo.update()
    else
      %LibraryPath{}
      |> LibraryPath.changeset(Map.put(attrs, :path, runtime_path.path))
      |> Repo.insert()
    end
  end

  # Disables library paths that were created from env vars but are no longer in config
  defp disable_removed_env_paths(current_env_paths) do
    # Find all library paths that:
    # 1. Were created from environment variables (from_env: true)
    # 2. Are not already disabled
    # 3. Are NOT in the current env config
    LibraryPath
    |> where([lp], lp.from_env == true and lp.disabled == false)
    |> Repo.all()
    |> Enum.filter(fn lp -> not MapSet.member?(current_env_paths, lp.path) end)
    |> Enum.reduce(0, fn library_path, count ->
      case library_path
           |> LibraryPath.changeset(%{disabled: true})
           |> Repo.update() do
        {:ok, _} ->
          Logger.info("Disabled library path removed from env config: #{library_path.path}")
          count + 1

        {:error, changeset} ->
          Logger.warning(
            "Failed to disable library path #{library_path.path}: #{inspect(changeset.errors)}"
          )

          count
      end
    end)
  end

  # Populates library_path_id and relative_path for a single media file
  defp populate_media_file(media_file, all_library_paths) do
    # Skip if already fully populated
    if media_file.library_path_id && media_file.relative_path do
      {:ok, :skipped}
    else
      # Try to find the file path - prefer absolute path, fall back to reconstructing from relative
      file_path = get_file_path_for_matching(media_file, all_library_paths)

      case find_matching_library_path(file_path, all_library_paths) do
        nil ->
          {:ok, :orphaned}

        library_path ->
          relative_path =
            media_file.relative_path || calculate_relative_path(file_path, library_path.path)

          # Get database ID for library path (sync to DB if needed)
          library_path_id = get_or_create_library_path_id(library_path)

          media_file
          |> Ecto.Changeset.change(%{
            library_path_id: library_path_id,
            relative_path: relative_path
          })
          |> Repo.update()
          |> case do
            {:ok, _} -> {:ok, :updated}
            {:error, changeset} -> {:error, changeset}
          end
      end
    end
  end

  # Gets the file path to use for library path matching
  # Prefers absolute path, but can reconstruct from relative_path + library_path
  defp get_file_path_for_matching(media_file, all_library_paths) do
    cond do
      # Use absolute path if available
      media_file.path && media_file.path != "" ->
        media_file.path

      # Try to reconstruct from existing library_path_id and relative_path
      media_file.library_path_id && media_file.relative_path ->
        case Enum.find(all_library_paths, &(&1.id == media_file.library_path_id)) do
          nil -> nil
          library_path -> Path.join(library_path.path, media_file.relative_path)
        end

      # Try to match relative_path against all library paths
      media_file.relative_path ->
        # Find a library path where the relative_path exists
        Enum.find_value(all_library_paths, fn library_path ->
          full_path = Path.join(library_path.path, media_file.relative_path)

          if File.exists?(full_path) do
            full_path
          end
        end)

      true ->
        nil
    end
  end

  # Finds the library path that best matches the given file path.
  # Uses longest prefix matching - prefers the most specific path.
  defp find_matching_library_path(nil, _library_paths), do: nil

  defp find_matching_library_path(file_path, library_paths) do
    library_paths
    |> Enum.filter(fn library_path ->
      String.starts_with?(file_path, library_path.path)
    end)
    |> Enum.max_by(
      fn library_path -> String.length(library_path.path) end,
      fn -> nil end
    )
  end

  # Calculates the relative path by removing the library path prefix
  defp calculate_relative_path(file_path, library_path) do
    # Remove the library path prefix and any leading slash
    file_path
    |> String.replace_prefix(library_path, "")
    |> String.trim_leading("/")
  end

  # Gets the database ID for a library path, creating it if it's a runtime path
  defp get_or_create_library_path_id(%LibraryPath{id: id, path: path}) when is_binary(id) do
    if String.starts_with?(id, "runtime::") do
      # Runtime path - need to get/create database record by path
      case Repo.get_by(LibraryPath, path: path) do
        nil ->
          # This shouldn't happen if sync_from_runtime_config was called first
          # But we'll handle it gracefully
          Logger.warning("Runtime library path not found in database: #{path}")
          nil

        db_path ->
          db_path.id
      end
    else
      # Already a database ID
      id
    end
  end

  defp get_or_create_library_path_id(id) when is_binary(id), do: id
  defp get_or_create_library_path_id(nil), do: nil
end
