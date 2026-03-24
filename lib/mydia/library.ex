defmodule Mydia.Library do
  @moduledoc """
  The Library context handles media files and library management.
  """

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  alias Mydia.Repo
  alias Mydia.Library.{MediaFile, FileAnalyzer, PhashGenerator}
  alias Mydia.Library.FileParser.V2, as: FileParser

  require Logger

  @doc """
  Returns the total storage used by all media files in bytes.
  """
  def total_storage_bytes do
    MediaFile
    |> where([f], is_nil(f.trashed_at))
    |> select([f], type(sum(f.size), :integer))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  Returns the list of media files.

  ## Options
    - `:media_item_id` - Filter by media item
    - `:episode_id` - Filter by episode
    - `:library_path_id` - Filter by library path ID
    - `:library_path_type` - Filter by library path type (e.g., :adult, :music, :books)
    - `:preload` - List of associations to preload
  """
  def list_media_files(opts \\ []) do
    MediaFile
    |> apply_media_file_filters(opts)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Returns a list of unique media item IDs that have files in the given library path.
  """
  def list_media_ids_in_library_path(%{id: library_path_id}) do
    MediaFile
    |> where([mf], mf.library_path_id == ^library_path_id)
    |> where([mf], not is_nil(mf.media_item_id))
    |> where([mf], is_nil(mf.trashed_at))
    |> select([mf], mf.media_item_id)
    |> distinct(true)
    |> Repo.all()
  end

  @doc """
  Gets a single media file.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the media file does not exist.
  """
  def get_media_file!(id, opts \\ []) do
    MediaFile
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a single media file, returning nil if not found.

  ## Options
    - `:preload` - List of associations to preload

  Returns the media file or nil if not found.
  """
  def get_media_file(id, opts \\ []) do
    MediaFile
    |> maybe_preload(opts[:preload])
    |> Repo.get(id)
  end

  @doc """
  Gets adjacent media files (previous and next) for navigation.

  Files are ordered by insertion date (newest first) to match the default
  listing order in the adult library index.

  ## Options
    - `:library_path_type` - Filter by library path type (e.g., :adult)

  Returns `{previous_file, next_file}` where either can be nil if at the boundary.
  """
  def get_adjacent_media_files(current_file_id, opts \\ []) do
    # Build base query with optional library type filter
    base_query =
      MediaFile
      |> apply_media_file_filters(opts)
      |> order_by([f], desc: f.inserted_at, desc: f.id)

    # Get the current file to find its position
    current_file = Repo.get!(MediaFile, current_file_id)

    # Previous file: files inserted after the current one (newer)
    previous_file =
      base_query
      |> where(
        [f],
        f.inserted_at > ^current_file.inserted_at or
          (f.inserted_at == ^current_file.inserted_at and f.id > ^current_file_id)
      )
      |> order_by([f], asc: f.inserted_at, asc: f.id)
      |> limit(1)
      |> Repo.one()

    # Next file: files inserted before the current one (older)
    next_file =
      base_query
      |> where(
        [f],
        f.inserted_at < ^current_file.inserted_at or
          (f.inserted_at == ^current_file.inserted_at and f.id < ^current_file_id)
      )
      |> limit(1)
      |> Repo.one()

    {previous_file, next_file}
  end

  @doc """
  Gets a media file by absolute path.

  Matches the path against all library paths to find the relative path,
  then queries by relative_path and library_path_id.

  Returns nil if no matching file is found.
  """
  def get_media_file_by_path(absolute_path, opts \\ []) do
    alias Mydia.Settings

    # Get all library paths to match the absolute path
    library_paths = Settings.list_library_paths()

    # Calculate relative path and library_path_id
    {library_path_id, relative_path} = calculate_relative_path(absolute_path, library_paths)

    case {library_path_id, relative_path} do
      {nil, _} ->
        # No matching library path found
        nil

      {_, nil} ->
        # No relative path calculated
        nil

      {lp_id, rel_path} ->
        # Query by relative_path and library_path_id
        get_media_file_by_relative_path(lp_id, rel_path, opts)
    end
  end

  @doc """
  Gets a media file by its relative path and library_path_id.
  """
  def get_media_file_by_relative_path(library_path_id, relative_path, opts \\ []) do
    query =
      MediaFile
      |> where([f], f.library_path_id == ^library_path_id and f.relative_path == ^relative_path)

    query =
      if Keyword.get(opts, :include_trashed, false),
        do: query,
        else: where(query, [f], is_nil(f.trashed_at))

    query
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Creates a media file.
  """
  def create_media_file(attrs \\ %{}) do
    %MediaFile{}
    |> MediaFile.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates a media file during library scanning.
  Parent association is optional and will be set later during metadata enrichment.

  Automatically extracts technical metadata (codec, resolution, container) via FFprobe
  using the library_path_id and relative_path to compute the absolute path.
  """
  def create_scanned_media_file(attrs \\ %{}) do
    # Extract technical metadata by computing absolute path from library_path + relative_path
    attrs = maybe_extract_technical_metadata(attrs)

    %MediaFile{}
    |> MediaFile.scan_changeset(attrs)
    |> Repo.insert()
  end

  defp maybe_extract_technical_metadata(
         %{library_path_id: library_path_id, relative_path: relative_path} = attrs
       )
       when is_binary(relative_path) do
    # Get library path to compute absolute path
    library_path =
      try do
        Mydia.Settings.get_library_path!(library_path_id)
      rescue
        _ -> nil
      end

    case library_path do
      nil ->
        attrs

      library_path ->
        absolute_path = Path.join(library_path.path, relative_path)

        case FileAnalyzer.analyze(absolute_path) do
          {:ok, analysis} ->
            # Build metadata map with duration and container
            metadata =
              %{}
              |> maybe_put_metadata("duration", analysis.duration)
              |> maybe_put_metadata("container", analysis.container)

            alias Mydia.Streaming.Codec

            attrs
            |> Map.put(:codec, Codec.normalize_video_codec(analysis.codec))
            |> Map.put(:audio_codec, Codec.normalize_audio_codec(analysis.audio_codec))
            |> Map.put(:resolution, analysis.resolution)
            |> Map.put(:bitrate, analysis.bitrate)
            |> Map.put(:hdr_format, analysis.hdr_format)
            |> maybe_put_if_not_empty(:metadata, metadata)

          {:error, reason} ->
            Logger.warning("Failed to extract technical metadata",
              path: absolute_path,
              reason: inspect(reason)
            )

            attrs
        end
    end
  end

  defp maybe_extract_technical_metadata(attrs), do: attrs

  defp maybe_put_metadata(map, _key, nil), do: map
  defp maybe_put_metadata(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_if_not_empty(attrs, _key, map) when map == %{}, do: attrs
  defp maybe_put_if_not_empty(attrs, key, map), do: Map.put(attrs, key, map)

  @doc """
  Updates a media file.
  """
  def update_media_file(%MediaFile{} = media_file, attrs) do
    media_file
    |> MediaFile.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates a media file during library scanning.

  Uses scan_changeset which allows orphaned files (files not yet matched to
  a media_item or episode) to be updated without validation errors.
  """
  def update_media_file_scan(%MediaFile{} = media_file, attrs) do
    media_file
    |> MediaFile.scan_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Marks a media file as verified.
  """
  def verify_media_file(%MediaFile{} = media_file) do
    media_file
    |> Ecto.Changeset.change(verified_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc """
  Deletes a media file.
  """
  def delete_media_file(%MediaFile{} = media_file) do
    Repo.delete(media_file)
  end

  @doc """
  Moves a media file to trash by setting `trashed_at` to now.

  Trashed files are excluded from all queries by default and will be
  permanently deleted after the configured retention period (default 30 days).
  """
  def trash_media_file(%MediaFile{} = media_file) do
    media_file
    |> Ecto.Changeset.change(trashed_at: DateTime.utc_now() |> DateTime.truncate(:second))
    |> Repo.update()
  end

  @doc """
  Restores a trashed media file by clearing `trashed_at`.
  """
  def restore_media_file(%MediaFile{} = media_file) do
    media_file
    |> Ecto.Changeset.change(trashed_at: nil)
    |> Repo.update()
  end

  @doc """
  Permanently deletes all media files that have been trashed for longer than `days`.

  Returns `{:ok, count}` with the number of permanently deleted files.
  """
  def purge_old_trashed_media_files(days \\ 30) do
    cutoff = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-days, :day)

    {count, _} =
      from(f in MediaFile,
        where: not is_nil(f.trashed_at) and f.trashed_at < ^cutoff
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Deletes the physical file from disk for a media file record.

  Returns `:ok` if the file was successfully deleted or doesn't exist,
  `{:error, reason}` if deletion failed.

  This function should be called before deleting the database record
  to ensure the file path is available.

  The library_path association must be preloaded.
  """
  def delete_media_file_from_disk(%MediaFile{} = media_file) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        Logger.error("Cannot delete media file from disk - path could not be resolved",
          media_file_id: media_file.id
        )

        {:error, :path_not_resolved}

      absolute_path ->
        if File.exists?(absolute_path) do
          case File.rm(absolute_path) do
            :ok ->
              Logger.info("Deleted media file from disk", path: absolute_path)
              :ok

            {:error, reason} ->
              Logger.error("Failed to delete media file from disk",
                path: absolute_path,
                reason: inspect(reason)
              )

              {:error, reason}
          end
        else
          # File doesn't exist, consider it a success
          Logger.debug("Media file already doesn't exist on disk", path: absolute_path)
          :ok
        end
    end
  end

  @doc """
  Deletes physical files from disk for a list of media files.

  Returns a tuple `{:ok, success_count, error_count}` with counts of
  successfully deleted and failed deletions.
  """
  def delete_media_files_from_disk(media_files) when is_list(media_files) do
    results =
      Enum.map(media_files, fn file ->
        delete_media_file_from_disk(file)
      end)

    success_count = Enum.count(results, &(&1 == :ok))
    error_count = Enum.count(results, &match?({:error, _}, &1))

    Logger.info("Bulk file deletion from disk completed",
      success: success_count,
      errors: error_count,
      total: length(media_files)
    )

    {:ok, success_count, error_count}
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking media file changes.
  """
  def change_media_file(%MediaFile{} = media_file, attrs \\ %{}) do
    MediaFile.changeset(media_file, attrs)
  end

  @doc """
  Gets all media files for a media item.
  """
  def get_media_files_for_item(media_item_id, opts \\ []) do
    list_media_files([media_item_id: media_item_id] ++ opts)
  end

  @doc """
  Gets all media files for an episode.
  """
  def get_media_files_for_episode(episode_id, opts \\ []) do
    list_media_files([episode_id: episode_id] ++ opts)
  end

  @doc """
  Matches unassociated media files to their episodes for a TV show.

  Finds all media files that are linked to a media_item but not to specific episodes,
  parses their filenames to extract season/episode information, and associates them
  with the correct episode records.

  Returns `{:ok, matched_count}` where matched_count is the number of files that
  were successfully matched to episodes.

  ## Parameters
    - `media_item_id` - The ID of the TV show media item

  ## Examples

      iex> match_files_to_episodes("some-uuid")
      {:ok, 8}
  """
  def match_files_to_episodes(media_item_id) do
    # Get all media files for this item that don't have an episode_id
    unmatched_files =
      MediaFile
      |> where([mf], mf.media_item_id == ^media_item_id)
      |> where([mf], is_nil(mf.episode_id))
      |> where([mf], is_nil(mf.trashed_at))
      |> Repo.all()

    Logger.info(
      "Found #{length(unmatched_files)} unmatched files for media item #{media_item_id}"
    )

    # Match each file to an episode
    matched_count =
      Enum.reduce(unmatched_files, 0, fn media_file, count ->
        case match_file_to_episode(media_file, media_item_id) do
          {:ok, _} -> count + 1
          {:error, _} -> count
        end
      end)

    Logger.info("Successfully matched #{matched_count} files to episodes")

    {:ok, matched_count}
  end

  defp match_file_to_episode(media_file, media_item_id) do
    # Use relative_path for filename parsing
    filename =
      case media_file.relative_path do
        nil ->
          Logger.warning("Media file missing relative_path during episode matching",
            media_file_id: media_file.id
          )

          # Cannot match without relative_path
          nil

        relative_path ->
          Path.basename(relative_path)
      end

    # Parse the filename to extract season/episode information
    if is_nil(filename) do
      {:error, :no_relative_path}
    else
      parsed_info = FileParser.parse(filename)
      season = parsed_info.season
      episode_numbers = parsed_info.episodes

      if is_integer(season) and is_list(episode_numbers) and length(episode_numbers) > 0 do
        # For multi-episode files, we'll just match to the first episode
        episode_number = List.first(episode_numbers)

        # Find the matching episode
        case Mydia.Media.get_episode_by_number(media_item_id, season, episode_number) do
          nil ->
            Logger.debug("No episode found for file",
              filename: filename,
              season: season,
              episode: episode_number
            )

            {:error, :episode_not_found}

          episode ->
            # Update the media file with the episode_id, keeping media_item_id
            case update_media_file(media_file, %{episode_id: episode.id}) do
              {:ok, updated_file} ->
                Logger.debug("Matched file to episode",
                  filename: filename,
                  season: season,
                  episode: episode_number,
                  episode_id: episode.id
                )

                {:ok, updated_file}

              {:error, reason} ->
                Logger.warning("Failed to update media file",
                  filename: filename,
                  reason: inspect(reason)
                )

                {:error, reason}
            end
        end
      else
        Logger.debug("File did not contain valid episode information", filename: filename)
        {:error, :no_episode_info}
      end
    end
  end

  @doc """
  Re-scans a TV series directory to discover and import new episode files.

  This function performs a comprehensive re-scan of a TV series:
  1. Finds the series base directory from existing media files
  2. Scans the directory for all video files
  3. Creates MediaFile records for newly discovered files
  4. Refreshes episode metadata from TMDB
  5. Matches files to episodes

  Returns `{:ok, result_map}` with statistics about the re-scan, or `{:error, reason}`.

  ## Result Map
    - `:new_files` - Number of new files discovered and added
    - `:matched` - Number of files matched to episodes
    - `:errors` - List of error tuples for files that failed to process

  ## Examples

      iex> rescan_series("media-item-uuid")
      {:ok, %{new_files: 3, matched: 3, errors: []}}
  """
  def rescan_series(media_item_id) do
    alias Mydia.Library.Scanner
    alias Mydia.Media
    alias Mydia.Settings

    # Get media item and verify it's a TV show
    media_item = Media.get_media_item!(media_item_id)
    library_paths = Settings.list_library_paths()

    if media_item.type != "tv_show" do
      {:error, :not_a_tv_show}
    else
      # Find base directory from existing media files
      case find_series_base_directory(media_item_id, library_paths) do
        {:ok, base_directory} ->
          Logger.info("Re-scanning TV series",
            media_item_id: media_item_id,
            title: media_item.title,
            directory: base_directory
          )

          # Scan directory for all video files
          case Scanner.scan(base_directory, recursive: true) do
            {:ok, scan_result} ->
              # Get existing media file paths for this series
              existing_files = get_media_files_for_item(media_item_id, preload: [:library_path])

              existing_paths =
                existing_files
                |> Enum.map(&MediaFile.absolute_path/1)
                |> Enum.reject(&is_nil/1)
                |> MapSet.new()

              # Find new files (not already in database)
              new_files =
                scan_result.files
                |> Enum.reject(fn file_info -> MapSet.member?(existing_paths, file_info.path) end)

              # Find files in DB that are no longer on disk
              scanned_paths =
                scan_result.files
                |> Enum.map(& &1.path)
                |> MapSet.new()

              missing_files =
                Enum.reject(existing_files, fn file ->
                  case MediaFile.absolute_path(file) do
                    nil -> true
                    path -> MapSet.member?(scanned_paths, path)
                  end
                end)

              trashed_count =
                Enum.count(missing_files, fn file ->
                  match?({:ok, _}, trash_media_file(file))
                end)

              Logger.info("Found new files during re-scan",
                new_file_count: length(new_files),
                trashed_files: trashed_count,
                total_scanned: length(scan_result.files)
              )

              # Create MediaFile records for new files
              {created_count, create_errors} =
                create_media_files_for_series(new_files, media_item_id, library_paths)

              # Refresh episodes from TMDB to ensure we have all episode metadata
              case Media.refresh_episodes_for_tv_show(media_item, season_monitoring: "all") do
                {:ok, episode_count} ->
                  Logger.info("Refreshed episode metadata",
                    media_item_id: media_item_id,
                    episode_count: episode_count
                  )

                {:error, reason} ->
                  Logger.warning("Failed to refresh episodes during re-scan",
                    media_item_id: media_item_id,
                    reason: inspect(reason)
                  )
              end

              # Match unassociated files to episodes
              {:ok, matched_count} = match_files_to_episodes(media_item_id)

              Logger.info("Re-scan complete",
                media_item_id: media_item_id,
                new_files: created_count,
                deleted_files: trashed_count,
                matched: matched_count,
                errors: length(create_errors)
              )

              {:ok,
               %{
                 new_files: created_count,
                 deleted_files: trashed_count,
                 matched: matched_count,
                 errors: create_errors
               }}

            {:error, :not_found} ->
              # Directory no longer exists — trash all files for the series
              existing_files =
                get_media_files_for_item(media_item_id, preload: [:library_path])

              trashed_count =
                Enum.count(existing_files, fn file ->
                  match?({:ok, _}, trash_media_file(file))
                end)

              Logger.info("Series directory missing, trashed all files",
                media_item_id: media_item_id,
                trashed_files: trashed_count
              )

              {:ok,
               %{
                 new_files: 0,
                 deleted_files: trashed_count,
                 matched: 0,
                 errors: []
               }}

            {:error, reason} ->
              Logger.error("Failed to scan directory",
                directory: base_directory,
                reason: inspect(reason)
              )

              {:error, :scan_failed}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Re-scans a specific season of a TV series to discover and import new episode files.

  Similar to `rescan_series/1` but scoped to a single season.

  Returns `{:ok, result_map}` with statistics about the re-scan, or `{:error, reason}`.

  ## Examples

      iex> rescan_season("media-item-uuid", 1)
      {:ok, %{new_files: 2, matched: 2, errors: []}}
  """
  def rescan_season(media_item_id, season_number) do
    alias Mydia.Library.Scanner
    alias Mydia.Media
    alias Mydia.Settings

    # Get media item and verify it's a TV show
    media_item = Media.get_media_item!(media_item_id)
    library_paths = Settings.list_library_paths()

    if media_item.type != "tv_show" do
      {:error, :not_a_tv_show}
    else
      # Find base directory from existing media files
      case find_series_base_directory(media_item_id, library_paths) do
        {:ok, base_directory} ->
          Logger.info("Re-scanning TV series season",
            media_item_id: media_item_id,
            title: media_item.title,
            season: season_number,
            directory: base_directory
          )

          # Scan directory for all video files
          case Scanner.scan(base_directory, recursive: true) do
            {:ok, scan_result} ->
              # Parse all scanned files and filter to this season
              season_files =
                scan_result.files
                |> Enum.filter(fn file_info ->
                  parsed = FileParser.parse(Path.basename(file_info.path))
                  parsed.season == season_number
                end)

              # Get existing media file paths for this series (with episode for season scoping)
              existing_files =
                get_media_files_for_item(media_item_id, preload: [:library_path, :episode])

              existing_paths =
                existing_files
                |> Enum.map(&MediaFile.absolute_path/1)
                |> Enum.reject(&is_nil/1)
                |> MapSet.new()

              # Find new files for this season
              new_files =
                season_files
                |> Enum.reject(fn file_info -> MapSet.member?(existing_paths, file_info.path) end)

              # Find files in DB for this season that are no longer on disk
              scanned_paths =
                season_files
                |> Enum.map(& &1.path)
                |> MapSet.new()

              missing_files =
                existing_files
                |> Enum.filter(fn file ->
                  # Only consider files belonging to this season
                  belongs_to_season =
                    cond do
                      file.episode && file.episode.season_number == season_number ->
                        true

                      is_nil(file.episode) ->
                        # Unmatched file: use filename parsing to determine season
                        parsed = FileParser.parse(Path.basename(file.relative_path || ""))
                        parsed.season == season_number

                      true ->
                        false
                    end

                  belongs_to_season &&
                    case MediaFile.absolute_path(file) do
                      nil -> false
                      path -> not MapSet.member?(scanned_paths, path)
                    end
                end)

              trashed_count =
                Enum.count(missing_files, fn file ->
                  match?({:ok, _}, trash_media_file(file))
                end)

              Logger.info("Found new files for season during re-scan",
                season: season_number,
                new_file_count: length(new_files),
                trashed_files: trashed_count,
                total_season_files: length(season_files)
              )

              # Create MediaFile records for new files
              {created_count, create_errors} =
                create_media_files_for_series(new_files, media_item_id, library_paths)

              # Refresh episodes from TMDB for this season
              case Media.refresh_episodes_for_tv_show(media_item, season_monitoring: "all") do
                {:ok, episode_count} ->
                  Logger.info("Refreshed episode metadata for season",
                    media_item_id: media_item_id,
                    season: season_number,
                    episode_count: episode_count
                  )

                {:error, reason} ->
                  Logger.warning("Failed to refresh episodes during season re-scan",
                    media_item_id: media_item_id,
                    season: season_number,
                    reason: inspect(reason)
                  )
              end

              # Match unassociated files to episodes (will match all seasons, but that's fine)
              {:ok, matched_count} = match_files_to_episodes(media_item_id)

              Logger.info("Season re-scan complete",
                media_item_id: media_item_id,
                season: season_number,
                new_files: created_count,
                deleted_files: trashed_count,
                matched: matched_count,
                errors: length(create_errors)
              )

              {:ok,
               %{
                 new_files: created_count,
                 deleted_files: trashed_count,
                 matched: matched_count,
                 errors: create_errors
               }}

            {:error, :not_found} ->
              # Directory no longer exists — trash all season files
              existing_files =
                get_media_files_for_item(media_item_id, preload: [:library_path, :episode])

              season_existing =
                Enum.filter(existing_files, fn file ->
                  cond do
                    file.episode && file.episode.season_number == season_number ->
                      true

                    is_nil(file.episode) ->
                      parsed = FileParser.parse(Path.basename(file.relative_path || ""))
                      parsed.season == season_number

                    true ->
                      false
                  end
                end)

              trashed_count =
                Enum.count(season_existing, fn file ->
                  match?({:ok, _}, trash_media_file(file))
                end)

              Logger.info("Season directory missing, trashed season files",
                media_item_id: media_item_id,
                season: season_number,
                trashed_files: trashed_count
              )

              {:ok,
               %{
                 new_files: 0,
                 deleted_files: trashed_count,
                 matched: 0,
                 errors: []
               }}

            {:error, reason} ->
              Logger.error("Failed to scan directory for season",
                directory: base_directory,
                season: season_number,
                reason: inspect(reason)
              )

              {:error, :scan_failed}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Re-scans a movie's directory for new files and creates MediaFile records.

  Discovers new video files in the movie's directory that aren't already
  in the database. For each new file, creates a MediaFile record and refreshes
  FFprobe metadata.

  Returns `{:ok, result_map}` with statistics about the re-scan, or `{:error, reason}`.

  ## Result Map
    - `:new_files` - Number of new files discovered and added
    - `:errors` - List of error tuples for files that failed to process

  ## Examples

      iex> rescan_movie("media-item-uuid")
      {:ok, %{new_files: 1, errors: []}}
  """
  def rescan_movie(media_item_id) do
    alias Mydia.Library.Scanner
    alias Mydia.Media
    alias Mydia.Settings

    # Get media item and verify it's a movie
    media_item = Media.get_media_item!(media_item_id)
    library_paths = Settings.list_library_paths()

    if media_item.type != "movie" do
      {:error, :not_a_movie}
    else
      # Find base directory from existing media files
      case find_movie_base_directory(media_item_id, library_paths) do
        {:ok, base_directory} ->
          Logger.info("Re-scanning movie",
            media_item_id: media_item_id,
            title: media_item.title,
            directory: base_directory
          )

          # Scan directory for video files (not recursive for movies)
          case Scanner.scan(base_directory, recursive: false) do
            {:ok, scan_result} ->
              # Get existing media file paths for this movie
              existing_files = get_media_files_for_item(media_item_id, preload: [:library_path])

              existing_paths =
                existing_files
                |> Enum.map(&MediaFile.absolute_path/1)
                |> Enum.reject(&is_nil/1)
                |> MapSet.new()

              # Find new files (not already in database)
              new_files =
                scan_result.files
                |> Enum.reject(fn file_info -> MapSet.member?(existing_paths, file_info.path) end)

              # Find files in DB that are no longer on disk
              scanned_paths =
                scan_result.files
                |> Enum.map(& &1.path)
                |> MapSet.new()

              missing_files =
                Enum.reject(existing_files, fn file ->
                  case MediaFile.absolute_path(file) do
                    nil -> true
                    path -> MapSet.member?(scanned_paths, path)
                  end
                end)

              trashed_count =
                Enum.count(missing_files, fn file ->
                  match?({:ok, _}, trash_media_file(file))
                end)

              Logger.info("Found new files during movie re-scan",
                new_file_count: length(new_files),
                trashed_files: trashed_count,
                total_scanned: length(scan_result.files)
              )

              # Create MediaFile records for new files
              {created_count, create_errors} =
                create_media_files_for_movie(new_files, media_item_id, library_paths)

              Logger.info("Movie re-scan complete",
                media_item_id: media_item_id,
                new_files: created_count,
                deleted_files: trashed_count,
                errors: length(create_errors)
              )

              {:ok,
               %{
                 new_files: created_count,
                 deleted_files: trashed_count,
                 errors: create_errors
               }}

            {:error, :not_found} ->
              # Directory no longer exists — trash all files for the movie
              existing_files =
                get_media_files_for_item(media_item_id, preload: [:library_path])

              trashed_count =
                Enum.count(existing_files, fn file ->
                  match?({:ok, _}, trash_media_file(file))
                end)

              Logger.info("Movie directory missing, trashed all files",
                media_item_id: media_item_id,
                trashed_files: trashed_count
              )

              {:ok,
               %{
                 new_files: 0,
                 deleted_files: trashed_count,
                 errors: []
               }}

            {:error, reason} ->
              Logger.error("Failed to scan directory",
                directory: base_directory,
                reason: inspect(reason)
              )

              {:error, :scan_failed}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # Finds the base directory for a TV series by looking at existing media file paths
  # Safety check: never allow scanning from a library path root.
  # Scanning the entire library would import every item as one media item.
  defp guard_not_library_root(dir, media_item_id, library_paths) do
    library_path_roots =
      library_paths
      |> Enum.map(& &1.path)
      |> MapSet.new()

    if MapSet.member?(library_path_roots, dir) do
      Logger.error("Detected directory is a library root — refusing to scan",
        media_item_id: media_item_id,
        directory: dir
      )

      {:error, :directory_is_library_root}
    else
      {:ok, dir}
    end
  end

  defp find_series_base_directory(media_item_id, library_paths) do
    media_files = get_media_files_for_item(media_item_id, preload: [:episode, :library_path])

    case media_files do
      [] ->
        Logger.warning("No media files found for series",
          media_item_id: media_item_id
        )

        {:error, :no_media_files}

      files ->
        # Extract the series folder name from each file's relative_path.
        # relative_path is like "SeriesName/Season 01/file.mkv" or "SeriesName/file.mkv"
        # The first path component is always the series folder.
        series_dirs =
          files
          |> Enum.map(fn file ->
            case {file.relative_path, file.library_path} do
              {nil, _} ->
                nil

              {_, nil} ->
                nil

              {relative_path, library_path} ->
                parts = Path.split(relative_path)

                # Guard: relative_path must have at least 2 components (folder/file).
                # A single component means the file is directly in the library root
                # with no series folder, which shouldn't happen for TV shows.
                if length(parts) >= 2 do
                  series_folder = List.first(parts)
                  Path.join(library_path.path, series_folder)
                end
            end
          end)
          |> Enum.reject(&is_nil/1)

        case series_dirs do
          [] ->
            Logger.error("Could not determine series base directory - no valid paths",
              media_item_id: media_item_id
            )

            {:error, :no_valid_paths}

          dirs ->
            # Use the most common series directory
            series_dir =
              dirs
              |> Enum.frequencies()
              |> Enum.max_by(fn {_dir, count} -> count end)
              |> elem(0)

            guard_not_library_root(series_dir, media_item_id, library_paths)
        end
    end
  end

  # Creates MediaFile records for a list of scanned files
  defp create_media_files_for_series(file_infos, media_item_id, library_paths) do
    results =
      Enum.map(file_infos, fn file_info ->
        # Find matching library_path and calculate relative_path
        {library_path_id, relative_path} = calculate_relative_path(file_info.path, library_paths)

        attrs = %{
          relative_path: relative_path,
          library_path_id: library_path_id,
          size: file_info.size,
          media_item_id: media_item_id
        }

        case create_scanned_media_file(attrs) do
          {:ok, media_file} ->
            Logger.debug("Created media file record",
              relative_path: relative_path,
              library_path_id: library_path_id,
              media_file_id: media_file.id
            )

            {:ok, media_file}

          {:error, changeset} ->
            Logger.warning("Failed to create media file record",
              path: file_info.path,
              errors: inspect(changeset.errors)
            )

            {:error, {:create_failed, file_info.path}}
        end
      end)

    created_count = Enum.count(results, &match?({:ok, _}, &1))
    errors = Enum.filter(results, &match?({:error, _}, &1))

    {created_count, errors}
  end

  # Finds the base directory for a movie by looking at existing media file paths
  defp find_movie_base_directory(media_item_id, library_paths) do
    media_files = get_media_files_for_item(media_item_id, preload: [:library_path])

    case media_files do
      [] ->
        Logger.warning("No media files found for movie",
          media_item_id: media_item_id
        )

        {:error, :no_media_files}

      files ->
        # Get the most common directory (movies are typically in a single directory)
        movie_dir =
          files
          |> Enum.map(fn file ->
            case MediaFile.absolute_path(file) do
              nil -> nil
              path -> Path.dirname(path)
            end
          end)
          |> Enum.reject(&is_nil/1)
          |> Enum.frequencies()
          |> Enum.max_by(fn {_dir, count} -> count end, fn -> {nil, 0} end)
          |> elem(0)

        case movie_dir do
          nil ->
            Logger.error("Could not determine movie base directory - no valid paths",
              media_item_id: media_item_id
            )

            {:error, :no_valid_paths}

          dir ->
            guard_not_library_root(dir, media_item_id, library_paths)
        end
    end
  end

  # Creates MediaFile records for a list of scanned movie files
  defp create_media_files_for_movie(file_infos, media_item_id, library_paths) do
    results =
      Enum.map(file_infos, fn file_info ->
        # Find matching library_path and calculate relative_path
        {library_path_id, relative_path} = calculate_relative_path(file_info.path, library_paths)

        attrs = %{
          relative_path: relative_path,
          library_path_id: library_path_id,
          size: file_info.size,
          media_item_id: media_item_id
        }

        case create_scanned_media_file(attrs) do
          {:ok, media_file} ->
            Logger.debug("Created media file record for movie",
              relative_path: relative_path,
              library_path_id: library_path_id,
              media_file_id: media_file.id
            )

            {:ok, media_file}

          {:error, changeset} ->
            Logger.warning("Failed to create media file record for movie",
              path: file_info.path,
              errors: inspect(changeset.errors)
            )

            {:error, {:create_failed, file_info.path}}
        end
      end)

    created_count = Enum.count(results, &match?({:ok, _}, &1))
    errors = Enum.filter(results, &match?({:error, _}, &1))

    {created_count, errors}
  end

  @doc """
  Finds media files similar to the given file based on perceptual hash.

  Uses the dHash algorithm to compare video content. Files with a Hamming distance
  less than or equal to the threshold are considered similar.

  ## Parameters
    - `media_file` - The MediaFile to find similar files for (must have phash set)
    - `opts` - Options:
      - `:threshold` - Maximum Hamming distance to consider similar (default: 10)
      - `:library_path_type` - Filter results to specific library type (e.g., :adult)
      - `:exclude_self` - Whether to exclude the input file from results (default: true)
      - `:preload` - Associations to preload on returned files

  ## Returns
    - `{:ok, similar_files}` - List of similar MediaFile structs with :distance key added
    - `{:error, :no_phash}` - The input file has no perceptual hash

  ## Examples

      {:ok, similar} = Library.find_similar_files(media_file)
      {:ok, similar} = Library.find_similar_files(media_file, threshold: 5)
  """
  @spec find_similar_files(MediaFile.t(), keyword()) ::
          {:ok, list(map())} | {:error, :no_phash}
  def find_similar_files(%MediaFile{phash: nil}, _opts) do
    {:error, :no_phash}
  end

  def find_similar_files(%MediaFile{phash: phash, id: file_id}, opts) do
    threshold = Keyword.get(opts, :threshold, 10)
    exclude_self = Keyword.get(opts, :exclude_self, true)

    # Get all files with phash values
    query =
      MediaFile
      |> where([f], not is_nil(f.phash))
      |> apply_media_file_filters(opts)

    query =
      if exclude_self do
        where(query, [f], f.id != ^file_id)
      else
        query
      end

    files =
      query
      |> maybe_preload(opts[:preload])
      |> Repo.all()

    # Calculate Hamming distance for each file and filter by threshold
    similar_files =
      files
      |> Enum.map(fn file ->
        distance = PhashGenerator.hamming_distance(phash, file.phash)
        {file, distance}
      end)
      |> Enum.filter(fn {_file, distance} -> distance <= threshold end)
      |> Enum.sort_by(fn {_file, distance} -> distance end)
      |> Enum.map(fn {file, distance} ->
        Map.put(file, :distance, distance)
      end)

    {:ok, similar_files}
  end

  @doc """
  Lists potential duplicate files across the library based on perceptual hashing.

  Groups files that are likely duplicates (same or very similar content) based
  on their perceptual hash similarity.

  ## Parameters
    - `opts` - Options:
      - `:threshold` - Maximum Hamming distance for duplicates (default: 5)
      - `:library_path_type` - Filter to specific library type
      - `:min_group_size` - Minimum files in a group to include (default: 2)
      - `:preload` - Associations to preload

  ## Returns
    A list of duplicate groups, where each group is a list of similar files.

  ## Examples

      groups = Library.find_duplicate_files(library_path_type: :adult)
      # Returns: [[file1, file2], [file3, file4, file5], ...]
  """
  @spec find_duplicate_files(keyword()) :: list(list(MediaFile.t()))
  def find_duplicate_files(opts \\ []) do
    threshold = Keyword.get(opts, :threshold, 5)
    min_group_size = Keyword.get(opts, :min_group_size, 2)

    # Get all files with phash values
    files =
      MediaFile
      |> where([f], not is_nil(f.phash))
      |> apply_media_file_filters(opts)
      |> maybe_preload(opts[:preload])
      |> Repo.all()

    # Group files by similarity using union-find approach
    groups = group_similar_files(files, threshold)

    # Filter to groups with at least min_group_size files
    groups
    |> Enum.filter(fn group -> length(group) >= min_group_size end)
    |> Enum.sort_by(fn group -> -length(group) end)
  end

  # Groups files by similarity using a simple clustering approach
  defp group_similar_files(files, threshold) do
    # Build a map of file_id -> file for quick lookup
    file_map = Map.new(files, fn f -> {f.id, f} end)

    # Build adjacency list of similar files
    adjacencies =
      files
      |> Enum.reduce(%{}, fn file, acc ->
        similar_ids =
          files
          |> Enum.filter(fn other ->
            other.id != file.id and
              PhashGenerator.hamming_distance(file.phash, other.phash) <= threshold
          end)
          |> Enum.map(& &1.id)

        Map.put(acc, file.id, similar_ids)
      end)

    # Find connected components
    find_connected_components(files, adjacencies, file_map)
  end

  # Finds connected components in the similarity graph
  defp find_connected_components(files, adjacencies, file_map) do
    # Start with all files unvisited
    all_ids = Enum.map(files, & &1.id) |> MapSet.new()

    {components, _visited} =
      Enum.reduce(all_ids, {[], MapSet.new()}, fn id, {components, visited} ->
        if MapSet.member?(visited, id) do
          {components, visited}
        else
          {component, new_visited} = bfs_component(id, adjacencies, visited)

          if length(component) > 0 do
            component_files = Enum.map(component, &Map.get(file_map, &1))
            {[component_files | components], new_visited}
          else
            {components, new_visited}
          end
        end
      end)

    components
  end

  # BFS to find all nodes in a connected component
  defp bfs_component(start_id, adjacencies, visited) do
    do_bfs([start_id], adjacencies, visited, [])
  end

  defp do_bfs([], _adjacencies, visited, component), do: {component, visited}

  defp do_bfs([id | rest], adjacencies, visited, component) do
    if MapSet.member?(visited, id) do
      do_bfs(rest, adjacencies, visited, component)
    else
      new_visited = MapSet.put(visited, id)
      neighbors = Map.get(adjacencies, id, [])
      unvisited_neighbors = Enum.reject(neighbors, &MapSet.member?(new_visited, &1))

      do_bfs(
        rest ++ unvisited_neighbors,
        adjacencies,
        new_visited,
        [id | component]
      )
    end
  end

  ## Private Functions

  # Calculates the relative path and library_path_id for an absolute file path
  # Returns {library_path_id, relative_path}
  defp calculate_relative_path(absolute_path, library_paths) do
    # Find the library_path that this file belongs to (longest matching prefix).
    # Normalize with trailing slash to prevent false matches like /media/tv matching /media/tv_extras.
    matching_path =
      library_paths
      |> Enum.filter(fn lp ->
        normalized = String.trim_trailing(lp.path, "/") <> "/"
        String.starts_with?(absolute_path, normalized)
      end)
      |> Enum.max_by(fn lp -> String.length(lp.path) end, fn -> nil end)

    case matching_path do
      nil ->
        Logger.warning("No matching library path found for file",
          path: absolute_path
        )

        # Return nil for both - the changeset will handle validation
        {nil, nil}

      library_path ->
        # Calculate relative path by removing the library path prefix
        relative_path =
          absolute_path
          |> String.replace_prefix(library_path.path, "")
          |> String.trim_leading("/")

        {library_path.id, relative_path}
    end
  end

  defp apply_media_file_filters(query, opts) do
    # Exclude trashed files by default unless include_trashed: true
    query =
      if Keyword.get(opts, :include_trashed, false),
        do: query,
        else: where(query, [f], is_nil(f.trashed_at))

    Enum.reduce(opts, query, fn
      {:include_trashed, _}, query ->
        query

      {:media_item_id, media_item_id}, query ->
        # For TV shows, files are associated through episodes, not directly
        # So we need to find files where:
        # 1. media_item_id matches directly (for movies/direct associations)
        # 2. episode_id belongs to an episode of this media_item (for TV shows)
        from(f in query,
          left_join: e in assoc(f, :episode),
          where: f.media_item_id == ^media_item_id or e.media_item_id == ^media_item_id
        )

      {:episode_id, episode_id}, query ->
        where(query, [f], f.episode_id == ^episode_id)

      {:library_path_id, library_path_id}, query ->
        # Filter files by library_path_id (for relative path scans)
        where(query, [f], f.library_path_id == ^library_path_id)

      {:library_path_type, library_type}, query ->
        # Filter files by their library path type (e.g., :adult, :music, :books)
        from(f in query,
          join: lp in assoc(f, :library_path),
          where: lp.type == ^library_type
        )

      {:path_prefix, _prefix}, query ->
        # Legacy option - no longer supported
        # Use :library_path_id instead
        Logger.warning("path_prefix filter is deprecated, use library_path_id instead")
        query

      _other, query ->
        query
    end)
  end

  @doc """
  Triggers a manual library scan for a specific library path.

  Returns an Oban job that will perform the scan.
  """
  def trigger_library_scan(library_path_id) do
    %{library_path_id: library_path_id}
    |> Mydia.Jobs.LibraryScanner.new()
    |> Oban.insert()
  end

  @doc """
  Triggers a manual library scan for all monitored library paths.

  Returns an Oban job that will perform the scan.
  """
  def trigger_full_library_scan do
    %{}
    |> Mydia.Jobs.LibraryScanner.new()
    |> Oban.insert()
  end

  @doc """
  Triggers a manual library scan for all adult library paths.

  This will scan for new/modified/deleted files and automatically
  generate thumbnails for any new files.

  Returns an Oban job that will perform the scan.
  """
  def trigger_adult_library_scan do
    %{library_type: "adult"}
    |> Mydia.Jobs.LibraryScanner.new()
    |> Oban.insert()
  end

  @doc """
  Triggers a metadata refresh for a specific media item.

  ## Options
    - `:fetch_episodes` - For TV shows, whether to refresh episodes (default: true)

  Returns an Oban job that will perform the refresh.
  """
  def trigger_metadata_refresh(media_item_id, opts \\ []) do
    fetch_episodes = Keyword.get(opts, :fetch_episodes, true)

    %{media_item_id: media_item_id, fetch_episodes: fetch_episodes}
    |> Mydia.Jobs.MetadataRefresh.new()
    |> Oban.insert()
  end

  @doc """
  Triggers a metadata refresh for all monitored media items.

  Returns an Oban job that will perform the refresh.
  """
  def trigger_full_metadata_refresh do
    %{refresh_all: true}
    |> Mydia.Jobs.MetadataRefresh.new()
    |> Oban.insert()
  end

  @doc """
  Refreshes file metadata for a specific media file by re-analyzing it.

  Uses both filename parsing and FFprobe analysis, preferring actual file metadata.

  The library_path association must be preloaded.

  Returns {:ok, updated_media_file} or {:error, reason}.
  """
  def refresh_file_metadata(%MediaFile{} = media_file) do
    case MediaFile.absolute_path(media_file) do
      nil ->
        Logger.error("Cannot refresh file metadata - path could not be resolved",
          file_id: media_file.id
        )

        {:error, :path_not_resolved}

      absolute_path ->
        if File.exists?(absolute_path) do
          # Use relative_path for filename parsing (more stable than absolute path)
          filename =
            case media_file.relative_path do
              nil -> Path.basename(absolute_path)
              relative_path -> Path.basename(relative_path)
            end

          # Parse filename for fallback metadata
          filename_metadata = FileParser.parse(filename)

          # Analyze actual file with FFprobe
          file_metadata =
            case FileAnalyzer.analyze(absolute_path) do
              {:ok, metadata} ->
                Logger.debug("Extracted file metadata via FFprobe",
                  file_id: media_file.id,
                  resolution: metadata.resolution,
                  codec: metadata.codec
                )

                metadata

              {:error, reason} ->
                Logger.warning("FFprobe analysis failed, using filename metadata only",
                  file_id: media_file.id,
                  reason: reason
                )

                %{
                  resolution: nil,
                  codec: nil,
                  audio_codec: nil,
                  bitrate: nil,
                  hdr_format: nil,
                  size: nil
                }
            end

          # Merge: prefer file analysis, fall back to filename
          update_attrs = %{
            resolution: file_metadata.resolution || filename_metadata.quality.resolution,
            codec: file_metadata.codec || filename_metadata.quality.codec,
            audio_codec: file_metadata.audio_codec || filename_metadata.quality.audio,
            bitrate: file_metadata.bitrate,
            hdr_format:
              file_metadata.hdr_format || Map.get(filename_metadata.quality, :hdr_format),
            size: file_metadata.size || File.stat!(absolute_path).size,
            verified_at: DateTime.utc_now() |> DateTime.truncate(:second)
          }

          case update_media_file(media_file, update_attrs) do
            {:ok, updated_file} ->
              Logger.info("Refreshed file metadata",
                file_id: media_file.id,
                path: absolute_path,
                resolution: updated_file.resolution,
                codec: updated_file.codec,
                audio: updated_file.audio_codec
              )

              {:ok, updated_file}

            {:error, changeset} ->
              Logger.error("Failed to update media file with refreshed metadata",
                file_id: media_file.id,
                errors: inspect(changeset.errors)
              )

              {:error, :update_failed}
          end
        else
          Logger.warning("File does not exist, cannot refresh metadata",
            file_id: media_file.id,
            path: absolute_path
          )

          {:error, :file_not_found}
        end
    end
  end

  @doc """
  Refreshes file metadata for a media file by ID.

  Returns {:ok, updated_media_file} or {:error, reason}.
  """
  def refresh_file_metadata_by_id(media_file_id) do
    media_file = get_media_file!(media_file_id, preload: [:library_path])
    refresh_file_metadata(media_file)
  end

  @doc """
  Checks if a torrent from a download client has already been imported to the library.

  Returns true if any media_file has this client_id in its metadata, false otherwise.
  This is used to prevent re-processing torrents that are seeding after import.
  """
  def torrent_already_imported?(client_name, client_id) do
    query =
      from f in MediaFile,
        where: ^Mydia.DB.json_equals(:metadata, "$.download_client", client_name),
        where: ^Mydia.DB.json_equals(:metadata, "$.download_client_id", client_id)

    Repo.exists?(query)
  end

  @doc """
  Refreshes file metadata for all media files in the library.

  This can be a long-running operation. Returns the count of successfully refreshed files.
  """
  def refresh_all_file_metadata do
    media_files = list_media_files(preload: [:library_path])

    Logger.info("Starting bulk metadata refresh", total_files: length(media_files))

    results =
      Enum.map(media_files, fn file ->
        case refresh_file_metadata(file) do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end
      end)

    success_count = Enum.count(results, &(&1 == :ok))
    error_count = Enum.count(results, &(&1 == :error))

    Logger.info("Completed bulk metadata refresh",
      success: success_count,
      errors: error_count
    )

    {:ok, success_count}
  end

  ## Import Sessions

  alias Mydia.Library.ImportSession

  @doc """
  Creates a new import session for a user.
  """
  def create_import_session(attrs \\ %{}) do
    attrs
    |> ImportSession.create_changeset()
    |> Repo.insert()
  end

  @doc """
  Gets the active import session for a user.
  Returns nil if no active session exists.
  """
  def get_active_import_session(user_id) do
    ImportSession
    |> where([s], s.user_id == ^user_id and s.status == :active)
    |> order_by([s], desc: s.updated_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Gets an import session by ID.
  Returns nil if not found.
  """
  def get_import_session(id) do
    Repo.get(ImportSession, id)
  end

  @doc """
  Gets an import session by ID.
  Raises Ecto.NoResultsError if not found.
  """
  def get_import_session!(id) do
    Repo.get!(ImportSession, id)
  end

  @doc """
  Updates an import session.
  """
  def update_import_session(%ImportSession{} = session, attrs) do
    session
    |> ImportSession.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Marks an import session as completed.
  """
  def complete_import_session(%ImportSession{} = session) do
    session
    |> ImportSession.complete_changeset()
    |> Repo.update()
  end

  @doc """
  Abandons all active import sessions for a user.
  This is called when starting a new import session.
  """
  def abandon_active_import_sessions(user_id) do
    from(s in ImportSession,
      where: s.user_id == ^user_id and s.status == :active
    )
    |> Repo.update_all(
      set: [status: :abandoned, updated_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
  end

  @doc """
  Deletes expired import sessions.
  Returns the count of deleted sessions.
  """
  def delete_expired_import_sessions do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {count, _} =
      from(s in ImportSession,
        where: s.expires_at < ^now
      )
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Deletes completed import sessions older than the given number of days.
  Returns the count of deleted sessions.
  """
  def delete_old_completed_sessions(days \\ 7) do
    cutoff = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.add(-days, :day)

    {count, _} =
      from(s in ImportSession,
        where: s.status == :completed and s.completed_at < ^cutoff
      )
      |> Repo.delete_all()

    {:ok, count}
  end
end
