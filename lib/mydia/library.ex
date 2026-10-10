defmodule Mydia.Library do
  @moduledoc """
  The Library context handles media files and library management.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Accounts.Scope
  alias Mydia.Library.{EpisodeLinks, MediaFile, MediaFiles}
  alias Mydia.Library.ReleaseParser, as: FileParser

  require Logger

  ## Media files

  defdelegate total_storage_bytes(), to: Mydia.Library.MediaFiles
  defdelegate media_file_count(), to: Mydia.Library.MediaFiles
  defdelegate list_media_files(opts \\ []), to: Mydia.Library.MediaFiles
  defdelegate list_media_ids_in_library_path(library_path), to: Mydia.Library.MediaFiles
  defdelegate get_media_file!(id, opts \\ []), to: Mydia.Library.MediaFiles
  defdelegate get_media_file(id, opts \\ []), to: Mydia.Library.MediaFiles
  defdelegate get_media_file_by_path(absolute_path, opts \\ []), to: Mydia.Library.MediaFiles

  defdelegate get_media_file_by_relative_path(library_path_id, relative_path, opts \\ []),
    to: Mydia.Library.MediaFiles

  defdelegate list_media_files_by_relative_path(library_path_id, relative_path, opts \\ []),
    to: Mydia.Library.MediaFiles

  defdelegate episode_has_media_file?(episode_id), to: Mydia.Library.MediaFiles
  defdelegate create_media_file(attrs \\ %{}), to: Mydia.Library.MediaFiles
  defdelegate attach_candidate(candidate_id, target), to: Mydia.Library.MediaFiles
  defdelegate create_scanned_media_file(attrs \\ %{}), to: Mydia.Library.MediaFiles
  defdelegate update_media_file(media_file, attrs), to: Mydia.Library.MediaFiles
  defdelegate update_media_file_scan(media_file, attrs), to: Mydia.Library.MediaFiles
  defdelegate verify_media_file(media_file), to: Mydia.Library.MediaFiles
  defdelegate change_media_file(media_file, attrs \\ %{}), to: Mydia.Library.MediaFiles
  defdelegate get_media_files_for_item(media_item_id, opts \\ []), to: Mydia.Library.MediaFiles
  defdelegate get_media_files_for_episode(episode_id, opts \\ []), to: Mydia.Library.MediaFiles

  ## Analysis

  defdelegate apply_analysis(media_file, outcome), to: Mydia.Library.Analysis
  defdelegate reset_analysis_state(media_file), to: Mydia.Library.Analysis
  defdelegate refresh_file_metadata(media_file), to: Mydia.Library.Analysis
  defdelegate refresh_file_metadata_by_id(media_file_id), to: Mydia.Library.Analysis
  defdelegate repair_file_metadata(media_file), to: Mydia.Library.Analysis
  defdelegate apply_repair_analysis_for_test(media_file, result), to: Mydia.Library.Analysis
  defdelegate refresh_all_file_metadata(), to: Mydia.Library.Analysis

  ## Trash

  defdelegate delete_media_file(media_file, opts \\ []), to: Mydia.Library.Trash
  defdelegate trash_media_file(media_file, opts \\ []), to: Mydia.Library.Trash
  defdelegate restore_media_file(media_file), to: Mydia.Library.Trash
  defdelegate purge_old_trashed_media_files(days \\ 30), to: Mydia.Library.Trash
  defdelegate list_trashed_media_files(opts \\ []), to: Mydia.Library.Trash
  defdelegate count_trashed_media_files(), to: Mydia.Library.Trash
  defdelegate trashed_summary(), to: Mydia.Library.Trash
  defdelegate purge_media_file(media_file), to: Mydia.Library.Trash
  defdelegate get_trashed_media_file(id, opts \\ []), to: Mydia.Library.Trash
  defdelegate delete_media_file_from_disk(media_file), to: Mydia.Library.Trash
  defdelegate delete_path_from_disk(absolute_path), to: Mydia.Library.Trash

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

  ## Episode links

  defdelegate match_files_to_episodes(media_item_id), to: Mydia.Library.EpisodeLinks
  defdelegate link_file_to_episodes(media_file, episodes), to: Mydia.Library.EpisodeLinks
  defdelegate add_episode_links(media_file, episode_ids), to: Mydia.Library.EpisodeLinks
  defdelegate ensure_episode_link(media_file), to: Mydia.Library.EpisodeLinks

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
                get_media_files_for_item(media_item_id,
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

              trashed_count =
                missing_files
                |> reject_files_still_on_disk()
                |> Enum.count(fn file ->
                  match?({:ok, _}, trash_media_file(file, move: false, reason: :missing))
                end)

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
                get_media_files_for_item(media_item_id,
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

              trashed_count =
                missing_files
                |> reject_files_still_on_disk()
                |> Enum.count(fn file ->
                  match?({:ok, _}, trash_media_file(file, move: false, reason: :missing))
                end)

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
                get_media_files_for_item(media_item_id,
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

              trashed_count =
                missing_files
                |> reject_files_still_on_disk()
                |> Enum.count(fn file ->
                  match?({:ok, _}, trash_media_file(file, move: false, reason: :missing))
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
      get_media_files_for_item(media_item_id,
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

    case create_scanned_media_file(attrs) do
      {:ok, media_file} ->
        {:ok, _} = link_file_to_episodes(media_file, episodes)
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
      get_media_files_for_item(media_item_id, preload: [:library_path], include_extras: true)

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
        {library_path_id, relative_path} =
          MediaFiles.calculate_relative_path(file_info.path, library_paths)

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

  ## Private Functions

  @doc """
  Triggers a manual library scan for a specific library path.

  Returns an Oban job that will perform the scan.
  """
  @spec trigger_library_scan(binary()) :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def trigger_library_scan(library_path_id) do
    %{library_path_id: library_path_id}
    |> Mydia.Jobs.LibraryScanner.new()
    |> Mydia.Jobs.insert()
  end

  @doc """
  Triggers a library scan for all monitored library paths.

  ## Options

    - `:schedule_in` - Seconds to wait before the scan runs. Omitted by manual
      triggers, which should start immediately. Automatic callers pass
      `Mydia.Jobs.LibraryScanner.jitter_seconds/0` so that instances restarting
      on the same new image do not hit the metadata relay at once.

  Returns an Oban job that will perform the scan.
  """
  @spec trigger_full_library_scan(keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def trigger_full_library_scan(opts \\ []) do
    %{}
    |> Mydia.Jobs.LibraryScanner.new(Keyword.take(opts, [:schedule_in]))
    |> Mydia.Jobs.insert()
  end

  @doc """
  Triggers a metadata refresh for a specific media item.

  ## Options
    - `:fetch_episodes` - For TV shows, whether to refresh episodes (default: true)

  Returns an Oban job that will perform the refresh.
  """
  @spec trigger_metadata_refresh(binary(), keyword()) ::
          {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
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
  @spec trigger_full_metadata_refresh() :: {:ok, Oban.Job.t()} | {:error, Ecto.Changeset.t()}
  def trigger_full_metadata_refresh do
    %{refresh_all: true}
    |> Mydia.Jobs.MetadataRefresh.new()
    |> Oban.insert()
  end

  ## Download imports

  defdelegate torrent_already_imported?(client_name, client_id),
    to: Mydia.Library.DownloadImports

  defdelegate imported_torrent_pairs(pairs), to: Mydia.Library.DownloadImports
  defdelegate origin_download(media_file), to: Mydia.Library.DownloadImports

  defdelegate list_media_files_for_download(download, opts \\ []),
    to: Mydia.Library.DownloadImports

  defdelegate count_imported_files_by_download(download_ids), to: Mydia.Library.DownloadImports

  ## Import Runs

  alias Mydia.Library.ImportRun

  @doc """
  Starts an import run for a library path.

  Returns an error changeset when the path already has a run in flight. The
  guarantee is enforced by a partial unique index, so two tabs pressing Start
  simultaneously cannot both win.
  """
  @spec create_import_run(map()) :: {:ok, ImportRun.t()} | {:error, Ecto.Changeset.t()}
  def create_import_run(attrs) do
    attrs
    |> ImportRun.create_changeset()
    |> Repo.insert()
  end

  @doc """
  Starts a review-mode import run for every enabled library path that could
  hold `target` (a movie or an episode), or reuses the path's active run.

  Review mode records and matches files but never promotes, so this is safe
  to offer from an item page: it refreshes the candidates "Find file" ranks
  and imports nothing on its own.
  """
  @spec start_review_scans(Mydia.Media.MediaItem.t() | Mydia.Media.Episode.t(), term()) ::
          [ImportRun.t()]
  def start_review_scans(target, user_id) do
    types = Mydia.Library.CandidateSuggestions.compatible_library_types(target)

    Mydia.Settings.LibraryPath
    |> where([lp], lp.type in ^types and (lp.disabled == false or is_nil(lp.disabled)))
    |> Repo.all()
    |> Enum.flat_map(fn library_path ->
      case active_import_run(library_path.id) do
        %ImportRun{} = run -> [run]
        nil -> start_review_run(library_path, user_id)
      end
    end)
  end

  defp start_review_run(library_path, user_id) do
    # The run and its job commit together: a run with no job would stay
    # active forever and block every later scan of the path.
    result =
      Repo.transaction(fn ->
        with {:ok, run} <-
               create_import_run(%{
                 library_path_id: library_path.id,
                 user_id: user_id,
                 mode: :review
               }),
             {:ok, _job} <-
               %{"import_run_id" => run.id}
               |> Mydia.Jobs.ImportRun.new()
               |> Mydia.Jobs.insert() do
          run
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)

    case result do
      {:ok, run} ->
        [run]

      # Lost the one-active-run race to another starter; use theirs.
      {:error, %Ecto.Changeset{data: %ImportRun{}}} ->
        List.wrap(active_import_run(library_path.id))

      {:error, reason} ->
        Logger.warning("Failed to enqueue review scan",
          library_path_id: library_path.id,
          reason: inspect(reason)
        )

        []
    end
  end

  @doc """
  Fetches an import run by id, or nil.
  """
  @spec get_import_run(binary()) :: ImportRun.t() | nil
  def get_import_run(id), do: Repo.get(ImportRun, id)

  @doc """
  Returns the in-flight run for a library path, or nil.

  A `:stopping` run counts as in flight: the coordinator is still draining its
  current chunk and a second run would race it.
  """
  @spec active_import_run(binary()) :: ImportRun.t() | nil
  def active_import_run(library_path_id) do
    statuses = ImportRun.active_statuses()

    ImportRun
    |> where([r], r.library_path_id == ^library_path_id and r.status in ^statuses)
    |> Repo.one()
  end

  @doc """
  Returns the most recently started run for a library path, regardless of
  status, or nil if the path has never had one.

  Exists so a reload can still show what a finished, failed, or stopped run
  did, since `active_import_run/1` deliberately excludes terminal states (the
  coordinator and the single-active-run uniqueness guard both depend on that
  exclusion, so it is not widened here).
  """
  @spec last_import_run(binary()) :: ImportRun.t() | nil
  def last_import_run(library_path_id) do
    ImportRun
    |> where([r], r.library_path_id == ^library_path_id)
    |> order_by([r], desc: r.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Updates progress counters or lifecycle state on a run.
  """
  @spec update_import_run(ImportRun.t(), map()) ::
          {:ok, ImportRun.t()} | {:error, Ecto.Changeset.t()}
  def update_import_run(%ImportRun{} = run, attrs) do
    run
    |> ImportRun.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns every run currently in an active status, across all library paths.

  Exists for boot reconciliation (`Mydia.Jobs.ImportRun.reconcile_interrupted_runs/0`),
  which has to sweep the whole table rather than one path at a time.
  """
  @spec list_active_import_runs() :: [ImportRun.t()]
  def list_active_import_runs do
    statuses = ImportRun.active_statuses()

    ImportRun
    |> where([r], r.status in ^statuses)
    |> Repo.all()
  end

  @doc """
  Asks a run to stop at the next chunk boundary.

  Re-reads the row first, for the same reason `import_run_stopping?/1` does:
  the caller is holding a struct read before the click, and the coordinator
  may have reached a terminal state since. `:stopping` is an active status, so
  writing it over a terminal row would lock that library path out forever with
  no worker left alive to advance it. Returns `{:error, changeset}` when the
  run is no longer running.
  """
  @spec request_import_run_stop(ImportRun.t() | binary()) ::
          {:ok, ImportRun.t()} | {:error, Ecto.Changeset.t()}
  def request_import_run_stop(%ImportRun{id: id}), do: request_import_run_stop(id)

  def request_import_run_stop(id) when is_binary(id) do
    case get_import_run(id) do
      nil ->
        {:error,
         %ImportRun{}
         |> ImportRun.changeset(%{})
         |> Ecto.Changeset.add_error(:id, "import run no longer exists")}

      run ->
        update_import_run(run, %{status: :stopping})
    end
  end

  @doc """
  Re-reads a run and reports whether a stop has been requested.

  Re-reads rather than inspecting the passed struct because the coordinator
  holds a stale copy between chunks; the whole point is to observe a write made
  by another process.
  """
  @spec import_run_stopping?(ImportRun.t() | binary()) :: boolean()
  def import_run_stopping?(%ImportRun{id: id}), do: import_run_stopping?(id)

  def import_run_stopping?(id) when is_binary(id) do
    case Repo.get(ImportRun, id) do
      %ImportRun{status: :stopping} -> true
      _ -> false
    end
  end
end
