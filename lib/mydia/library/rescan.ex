defmodule Mydia.Library.Rescan do
  @moduledoc """
  Owns re-scanning a series, season or movie directory to discover new files and trash missing ones.
  """

  require Logger
  alias Mydia.Accounts.Scope
  alias Mydia.Library.{EpisodeLinks, MediaFile, MediaFiles, Relink, Trash}
  alias Mydia.Library.ReleaseParser, as: FileParser

  # The directory diff in the three re-scan paths proposes files as missing by
  # comparing path strings against a scan of one inferred directory. This is
  # the operator-facing check that confirms it: it names the path in a
  # warning log so a wrongly-called-missing row is visible, and it keeps the
  # re-scan from even attempting a trash that would now fail anyway.
  #
  # A row the diff called missing whose file is nevertheless sitting on disk is
  # not missing: it is a row whose stored path did not match the scan for some
  # other reason. A second row for the same file, a path that normalises
  # differently, a scan that could not read the directory, a file whose
  # extension is outside Scanner's list. Trashing it moves bytes out of the
  # library, which is how #653 emptied people's libraries.
  #
  # This check and trash_media_file/2's `move: false` run at different
  # times, so a file that reappears on disk in the gap between them (a
  # reconnecting mount, a concurrent import) can still slip past this
  # function. The `move: false` option the three re-scan callers pass is the
  # backstop for that: it refuses to move a file TrashStore finds present at
  # the moment it actually acts, no matter what this function saw earlier.
  # This function stays first because it is the only one of the two that can
  # name the path in a warning log.
  #
  # A row with no resolvable path is kept in the list. There is nothing to
  # check, and TrashStore.store/2 has nothing to move for it either.
  @spec reject_files_still_on_disk([MediaFile.t()]) :: [MediaFile.t()]
  defp reject_files_still_on_disk(candidates) do
    Enum.reject(candidates, fn media_file ->
      case MediaFile.absolute_path(media_file) do
        nil ->
          false

        path ->
          present? = File.exists?(path)

          if present? do
            Logger.warning(
              "Re-scan called a file missing that is still on disk; refusing to trash it",
              media_file_id: media_file.id,
              path: path
            )
          end

          present?
      end
    end)
  end

  # A file renamed in place shows up as one missing row and one new file, so
  # relink before trashing anything or creating rows. Returns the number of
  # rows trashed and the new files left to create.
  defp relink_then_trash(missing_files, new_files, library_paths) do
    {missing_files, new_files} =
      missing_files
      |> reject_files_still_on_disk()
      |> Relink.Scan.renamed(new_files, library_paths)

    trashed_count =
      Enum.count(missing_files, fn file ->
        match?({:ok, _}, Trash.trash_media_file(file, move: false, reason: :missing))
      end)

    {trashed_count, new_files}
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
  @spec rescan_series(binary()) :: {:ok, map()} | {:error, term()}
  def rescan_series(media_item_id) do
    alias Mydia.Library.Scanner
    alias Mydia.Media
    alias Mydia.Settings

    # Get media item and verify it's a TV show
    media_item = Media.get_media_item!(Scope.system(), media_item_id)
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
              existing_files =
                MediaFiles.get_media_files_for_item(media_item_id,
                  preload: [:library_path],
                  include_extras: true
                )

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

              {trashed_count, new_files} =
                relink_then_trash(missing_files, new_files, library_paths)

              Logger.info("Found new files during re-scan",
                new_file_count: length(new_files),
                trashed_files: trashed_count,
                total_scanned: length(scan_result.files)
              )

              # Refresh episodes before creating rows: a new file is attached only
              # once it names an episode the show has, so resolution needs them.
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

              %{created: created_count, staged: staged_count, errors: create_errors} =
                create_media_files_for_series(new_files, media_item, library_paths)

              Logger.info("Re-scan complete",
                media_item_id: media_item_id,
                new_files: created_count,
                staged: staged_count,
                deleted_files: trashed_count,
                errors: length(create_errors)
              )

              {:ok,
               %{
                 new_files: created_count,
                 deleted_files: trashed_count,
                 matched: created_count,
                 staged: staged_count,
                 errors: create_errors,
                 scan_errors: scan_result.errors
               }}

            {:error, :not_found} ->
              # A base directory that will not resolve is a failed scan, not
              # proof the library is empty. This branch used to trash every
              # file for the item, which physically moved the bytes of any
              # file that was still there: an unmounted share or a renamed
              # folder emptied the item (#653).
              Logger.error("Series re-scan base directory could not be read",
                media_item_id: media_item_id,
                directory: base_directory
              )

              {:error, :scan_failed}

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
  @spec rescan_season(binary(), integer()) :: {:ok, map()} | {:error, term()}
  def rescan_season(media_item_id, season_number) do
    alias Mydia.Library.Scanner
    alias Mydia.Media
    alias Mydia.Settings

    # Get media item and verify it's a TV show
    media_item = Media.get_media_item!(Scope.system(), media_item_id)
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
                MediaFiles.get_media_files_for_item(media_item_id,
                  preload: [:library_path, :episode],
                  include_extras: true
                )

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

              {trashed_count, new_files} =
                relink_then_trash(missing_files, new_files, library_paths)

              Logger.info("Found new files for season during re-scan",
                season: season_number,
                new_file_count: length(new_files),
                trashed_files: trashed_count,
                total_season_files: length(season_files)
              )

              # Refresh episodes before creating rows: a new file is attached only
              # once it names an episode the show has, so resolution needs them.
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

              %{created: created_count, staged: staged_count, errors: create_errors} =
                create_media_files_for_series(new_files, media_item, library_paths)

              Logger.info("Season re-scan complete",
                media_item_id: media_item_id,
                season: season_number,
                new_files: created_count,
                staged: staged_count,
                deleted_files: trashed_count,
                errors: length(create_errors)
              )

              {:ok,
               %{
                 new_files: created_count,
                 deleted_files: trashed_count,
                 matched: created_count,
                 staged: staged_count,
                 errors: create_errors,
                 scan_errors: scan_result.errors
               }}

            {:error, :not_found} ->
              # See rescan_series/1: a directory that will not resolve is a
              # failed scan, never a reason to trash the season's files (#653).
              Logger.error("Season re-scan base directory could not be read",
                media_item_id: media_item_id,
                season: season_number,
                directory: base_directory
              )

              {:error, :scan_failed}

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
  @spec rescan_movie(binary()) :: {:ok, map()} | {:error, term()}
  def rescan_movie(media_item_id) do
    alias Mydia.Library.Scanner
    alias Mydia.Media
    alias Mydia.Settings

    # Get media item and verify it's a movie
    media_item = Media.get_media_item!(Scope.system(), media_item_id)
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
              existing_files =
                MediaFiles.get_media_files_for_item(media_item_id,
                  preload: [:library_path],
                  include_extras: true
                )

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

              {trashed_count, new_files} =
                relink_then_trash(missing_files, new_files, library_paths)

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
                 errors: create_errors,
                 scan_errors: scan_result.errors
               }}

            {:error, :not_found} ->
              # See rescan_series/1: a directory that will not resolve is a
              # failed scan, never a reason to trash the movie's files (#653).
              Logger.error("Movie re-scan base directory could not be read",
                media_item_id: media_item_id,
                directory: base_directory
              )

              {:error, :scan_failed}

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
    media_files =
      MediaFiles.get_media_files_for_item(media_item_id,
        preload: [:episode, :library_path],
        include_extras: true
      )

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

        vote_base_directory(series_dirs, "series", media_item_id, library_paths)
    end
  end

  # The most common of `dirs` that still exists. Only existing directories
  # vote: a deleted folder must not outvote the one that holds the files.
  defp vote_base_directory(dirs, kind, media_item_id, library_paths) do
    case {dirs, Enum.filter(dirs, &File.dir?/1)} do
      {[], _} ->
        Logger.error("Could not determine #{kind} base directory - no valid paths",
          media_item_id: media_item_id
        )

        {:error, :no_valid_paths}

      {_, []} ->
        Logger.warning("No #{kind} directory exists on disk", media_item_id: media_item_id)

        {:error, :no_files_on_disk}

      {_, existing} ->
        existing
        |> Enum.frequencies()
        |> Enum.max_by(fn {_dir, count} -> count end)
        |> elem(0)
        |> guard_not_library_root(media_item_id, library_paths)
    end
  end

  # Creates rows for newly scanned files of a TV show. A file becomes a
  # media_files row only once it names an episode the show has. Anything else is
  # staged as an import candidate under the show's provider identity: a TV file
  # attached to the show itself is an orphan, and MediaFile.changeset/2 refuses it.
  defp create_media_files_for_series(file_infos, media_item, library_paths) do
    results = Enum.map(file_infos, &create_series_file(&1, media_item, library_paths))

    %{
      created: Enum.count(results, &match?({:ok, %MediaFile{}}, &1)),
      staged: Enum.count(results, &match?({:ok, :staged}, &1)),
      errors: Enum.filter(results, &match?({:error, _}, &1))
    }
  end

  defp create_series_file(file_info, media_item, library_paths) do
    case MediaFiles.calculate_relative_path(file_info.path, library_paths) do
      {nil, nil} ->
        {:error, {:create_failed, file_info.path}}

      {library_path_id, relative_path} ->
        library_path = Enum.find(library_paths, &(&1.id == library_path_id))

        case EpisodeLinks.resolve_file_episodes(relative_path, media_item.id, media_item.title) do
          {:ok, episodes} ->
            insert_series_file(file_info, library_path, relative_path, episodes)

          {:error, _reason} ->
            stage_series_file(file_info, media_item, library_path, relative_path)
        end
    end
  end

  defp insert_series_file(file_info, library_path, relative_path, [primary | _] = episodes) do
    attrs = %{
      relative_path: relative_path,
      library_path_id: library_path.id,
      size: file_info.size,
      episode_id: primary.id
    }

    case MediaFiles.create_scanned_media_file(attrs) do
      {:ok, media_file} ->
        {:ok, _} = EpisodeLinks.link_file_to_episodes(media_file, episodes)
        {:ok, media_file}

      {:error, changeset} ->
        Logger.warning("Failed to create media file record",
          path: file_info.path,
          errors: inspect(changeset.errors)
        )

        {:error, {:create_failed, file_info.path}}
    end
  end

  defp stage_series_file(file_info, media_item, library_path, relative_path) do
    case Mydia.ImportCandidates.stage_item_file(media_item, library_path, %{
           relative_path: relative_path,
           size: file_info.size,
           discovered_at: DateTime.utc_now() |> DateTime.truncate(:second)
         }) do
      {:ok, _candidate} ->
        {:ok, :staged}

      {:error, changeset} ->
        Logger.warning("Failed to stage scanned TV file for import",
          path: file_info.path,
          errors: inspect(changeset.errors)
        )

        {:error, {:stage_failed, file_info.path}}
    end
  end

  # Finds the base directory for a movie by looking at existing media file paths
  defp find_movie_base_directory(media_item_id, library_paths) do
    media_files =
      MediaFiles.get_media_files_for_item(media_item_id,
        preload: [:library_path],
        include_extras: true
      )

    case media_files do
      [] ->
        Logger.warning("No media files found for movie",
          media_item_id: media_item_id
        )

        {:error, :no_media_files}

      files ->
        # Get the most common directory (movies are typically in a single directory)
        dirs =
          files
          |> Enum.map(fn file ->
            case MediaFile.absolute_path(file) do
              nil -> nil
              path -> Path.dirname(path)
            end
          end)
          |> Enum.reject(&is_nil/1)

        vote_base_directory(dirs, "movie", media_item_id, library_paths)
    end
  end

  # Creates MediaFile records for a list of scanned movie files
  defp create_media_files_for_movie(file_infos, media_item_id, library_paths) do
    results =
      Enum.map(file_infos, fn file_info ->
        # Find matching library_path and calculate relative_path
        {library_path_id, relative_path} =
          MediaFiles.calculate_relative_path(file_info.path, library_paths)

        attrs = %{
          relative_path: relative_path,
          library_path_id: library_path_id,
          size: file_info.size,
          media_item_id: media_item_id
        }

        case MediaFiles.create_scanned_media_file(attrs) do
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
end
