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
  alias Mydia.{Library, Settings, Repo, Metadata}
  alias Mydia.Library.{MetadataMatcher, MetadataEnricher, FileParser, FileAnalyzer}

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    start_time = System.monotonic_time(:millisecond)
    library_path_id = Map.get(args, "library_path_id")

    result =
      case library_path_id do
        nil ->
          scan_all_libraries()

        id ->
          scan_single_library(id)
      end

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      :ok ->
        Logger.info("Library scan job completed",
          duration_ms: duration,
          library_path_id: library_path_id
        )

        :ok

      {:error, reason} ->
        Logger.error("Library scan job failed",
          error: inspect(reason),
          duration_ms: duration,
          library_path_id: library_path_id
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

    # Perform the file system scan
    progress_callback = fn count ->
      Logger.debug("Scan progress", library_path_id: library_path.id, files_scanned: count)
    end

    scan_result =
      case Library.Scanner.scan(library_path.path, progress_callback: progress_callback) do
        {:ok, result} -> result
        {:error, reason} -> raise "Scan failed: #{inspect(reason)}"
      end

    # Get existing files from database - only files within this library path
    # This prevents deleting files from other library paths during scan
    existing_files = Library.list_media_files(path_prefix: library_path.path)

    # Detect changes
    changes = Library.Scanner.detect_changes(scan_result, existing_files)

    # Process changes in a transaction (file operations only, no metadata enrichment)
    transaction_result =
      Repo.transaction(fn ->
        # Add new files (without metadata enrichment)
        new_media_files =
          Enum.map(changes.new_files, fn file_info ->
            case Library.create_scanned_media_file(%{
                   path: file_info.path,
                   size: file_info.size,
                   verified_at: DateTime.utc_now()
                 }) do
              {:ok, media_file} ->
                Logger.debug("Added new media file", path: file_info.path)
                {:ok, media_file, file_info}

              {:error, changeset} ->
                Logger.error("Failed to create media file",
                  path: file_info.path,
                  errors: inspect(changeset.errors)
                )

                {:error, file_info}
            end
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

        %{changes: changes, scan_result: scan_result, new_media_files: new_media_files}
      end)

    # After transaction commits, enrich new files with metadata (outside transaction)
    case transaction_result do
      {:ok, result} ->
        # Get metadata provider config
        metadata_config = Metadata.default_relay_config()

        # Process metadata enrichment for new files (outside transaction)
        Enum.each(result.new_media_files, fn
          {:ok, media_file, file_info} ->
            # Try to parse, match, and enrich the file
            process_media_file(media_file, file_info, metadata_config)

          {:error, _file_info} ->
            :ok
        end)

        # Initialize tracking for robust cleanup operations
        cleanup_stats = %{
          orphaned_files_fixed: 0,
          tv_orphans_fixed: 0,
          associations_updated: 0,
          invalid_paths_removed: 0
        }

        # 1. Re-enrich completely orphaned files (no media_item_id and no episode_id)
        completely_orphaned =
          existing_files
          |> Enum.filter(fn file ->
            is_nil(file.media_item_id) and is_nil(file.episode_id)
          end)

        cleanup_stats =
          if completely_orphaned != [] do
            Logger.info("Re-enriching completely orphaned files",
              count: length(completely_orphaned)
            )

            fixed_count =
              Enum.count(completely_orphaned, fn media_file ->
                file_info =
                  Enum.find(result.scan_result.files, fn f -> f.path == media_file.path end)

                if file_info do
                  Logger.debug("Re-enriching orphaned file", path: media_file.path)
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

        # 4. Track removed files with invalid paths
        cleanup_stats =
          Map.put(cleanup_stats, :invalid_paths_removed, length(result.changes.deleted_files))

        # Log cleanup summary
        if cleanup_stats.orphaned_files_fixed > 0 or cleanup_stats.tv_orphans_fixed > 0 or
             cleanup_stats.associations_updated > 0 or cleanup_stats.invalid_paths_removed > 0 do
          Logger.info("Cleanup summary",
            orphaned_files_fixed: cleanup_stats.orphaned_files_fixed,
            tv_orphans_fixed: cleanup_stats.tv_orphans_fixed,
            associations_updated: cleanup_stats.associations_updated,
            invalid_paths_removed: cleanup_stats.invalid_paths_removed
          )
        end

        {:ok, Map.put(result, :cleanup_stats, cleanup_stats)}

      error ->
        error
    end
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
             invalid_paths_removed: Map.get(cleanup_stats, :invalid_paths_removed, 0)
           }}
        )

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

        # Broadcast scan failed
        Phoenix.PubSub.broadcast(
          Mydia.PubSub,
          "library_scanner",
          {:library_scan_failed,
           %{library_path_id: library_path.id, type: library_path.type, error: error_message}}
        )

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

      # Broadcast scan failed
      Phoenix.PubSub.broadcast(
        Mydia.PubSub,
        "library_scanner",
        {:library_scan_failed,
         %{library_path_id: library_path.id, type: library_path.type, error: error_message}}
      )

      {:error, error}
  end

  # Checks if a library path can be updated in the database.
  # Runtime library paths (from environment variables) can't be updated.
  defp updatable_library_path?(%{id: id}) when is_binary(id) do
    !String.starts_with?(id, "runtime::")
  end

  defp updatable_library_path?(_), do: true

  defp process_media_file(media_file, file_info, metadata_config) do
    Logger.debug("Processing media file for metadata", path: file_info.path)

    # Try to match the file to metadata
    case MetadataMatcher.match_file(file_info.path, config: metadata_config) do
      {:ok, match_result} ->
        Logger.info("Matched media file",
          path: file_info.path,
          title: match_result.title,
          provider_id: match_result.provider_id,
          confidence: match_result.match_confidence
        )

        # Enrich with full metadata
        case MetadataEnricher.enrich(match_result,
               config: metadata_config,
               media_file_id: media_file.id
             ) do
          {:ok, media_item} ->
            Logger.info("Enriched media item",
              media_item_id: media_item.id,
              title: media_item.title
            )

            # Extract technical file metadata (resolution, codec, bitrate, etc.)
            extract_and_update_file_metadata(media_file, file_info)

          {:error, reason} ->
            Logger.warning("Failed to enrich media",
              path: file_info.path,
              reason: reason
            )
        end

      {:error, :unknown_media_type} ->
        Logger.debug("Could not determine media type",
          path: file_info.path
        )

      {:error, :no_matches_found} ->
        Logger.warning("No metadata matches found",
          path: file_info.path
        )

      {:error, :low_confidence_match} ->
        Logger.warning("Only low confidence matches found",
          path: file_info.path
        )

      {:error, reason} ->
        Logger.warning("Failed to match media file",
          path: file_info.path,
          reason: reason
        )
    end
  rescue
    error ->
      Logger.error("Exception while processing media file",
        path: file_info.path,
        error: Exception.message(error)
      )
  end

  # Attempts to fix an orphaned TV show file by matching it to an episode
  defp fix_orphaned_tv_file(media_file, metadata_config) do
    Logger.debug("Attempting to fix orphaned TV file",
      path: media_file.path,
      media_item_id: media_file.media_item_id
    )

    # Parse the filename to extract season/episode info
    parsed = FileParser.parse(Path.basename(media_file.path))

    case parsed do
      %{type: :tv_show, season: season, episodes: episodes}
      when not is_nil(season) and not is_nil(episodes) ->
        # Try to find the episode in the database
        # For multi-episode files, use the first episode
        episode_number = List.first(episodes)

        case Mydia.Media.get_episode_by_number(media_file.media_item_id, season, episode_number) do
          nil ->
            # Episode doesn't exist yet, try to fetch it from TMDB
            Logger.info("Episode not found, attempting to fetch from TMDB",
              media_item_id: media_file.media_item_id,
              season: season,
              episode: episode_number
            )

            # Fetch the media item to get TMDB ID
            media_item = Mydia.Media.get_media_item!(media_file.media_item_id)

            if media_item.tmdb_id do
              # Fetch season data from TMDB
              case Metadata.fetch_season(
                     metadata_config,
                     to_string(media_item.tmdb_id),
                     season
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
                      Logger.warning("Episode still not found after TMDB fetch",
                        media_item_id: media_file.media_item_id,
                        season: season,
                        episode: episode_number
                      )

                      false

                    episode ->
                      associate_file_with_episode(media_file, episode)
                  end

                {:error, reason} ->
                  Logger.warning("Failed to fetch season from TMDB",
                    media_item_id: media_file.media_item_id,
                    season: season,
                    reason: reason
                  )

                  false
              end
            else
              Logger.warning("Media item has no TMDB ID, cannot fetch episodes",
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
          path: media_file.path
        )

        false
    end
  rescue
    error ->
      Logger.error("Exception while fixing orphaned TV file",
        path: media_file.path,
        error: Exception.message(error)
      )

      false
  end

  # Re-validates a TV file's episode association by re-parsing the filename
  defp revalidate_tv_file_association(media_file) do
    # Parse the filename to see what season/episode it claims to be
    parsed = FileParser.parse(Path.basename(media_file.path))

    case parsed do
      %{type: :tv_show, season: season, episodes: episodes}
      when not is_nil(season) and not is_nil(episodes) ->
        # Get the first episode number (for multi-episode files)
        episode_number = List.first(episodes)

        # Check if this matches the current association
        if media_file.episode.season_number != season or
             media_file.episode.episode_number != episode_number do
          Logger.info("File association mismatch detected",
            path: media_file.path,
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
                    path: media_file.path,
                    old_episode:
                      "S#{media_file.episode.season_number}E#{media_file.episode.episode_number}",
                    new_episode: "S#{new_episode.season_number}E#{new_episode.episode_number}"
                  )

                  true

                {:error, reason} ->
                  Logger.error("Failed to update file association",
                    path: media_file.path,
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
      Logger.error("Exception while revalidating file association",
        path: media_file.path,
        error: Exception.message(error)
      )

      false
  end

  # Associates a media file with an episode
  # For TV shows, files should have episode_id set, not media_item_id
  # So we need to clear media_item_id when setting episode_id
  defp associate_file_with_episode(media_file, episode) do
    case Library.update_media_file(media_file, %{episode_id: episode.id, media_item_id: nil}) do
      {:ok, _updated_file} ->
        Logger.info("Associated file with episode",
          path: media_file.path,
          episode: "S#{episode.season_number}E#{episode.episode_number}"
        )

        true

      {:error, reason} ->
        Logger.error("Failed to associate file with episode",
          path: media_file.path,
          reason: inspect(reason)
        )

        false
    end
  rescue
    error ->
      Logger.error("Exception while associating file with episode",
        path: media_file.path,
        error: Exception.message(error)
      )

      false
  end

  # Creates episodes from TMDB season data
  defp create_episodes_from_season(media_item, season_data) do
    episodes = Map.get(season_data, :episodes, [])
    season_number = Map.get(season_data, :season_number)

    Enum.each(episodes, fn episode_data ->
      # Check if episode already exists
      existing_episode =
        Mydia.Media.get_episode_by_number(
          media_item.id,
          season_number,
          episode_data.episode_number
        )

      if is_nil(existing_episode) do
        attrs = %{
          media_item_id: media_item.id,
          season_number: season_number,
          episode_number: episode_data.episode_number,
          title: episode_data.name,
          air_date: parse_air_date(episode_data.air_date),
          metadata: episode_data,
          monitored: true
        }

        case Mydia.Media.create_episode(attrs) do
          {:ok, _episode} ->
            Logger.debug("Created episode from season data",
              media_item_id: media_item.id,
              season: season_number,
              episode: episode_data.episode_number
            )

          {:error, reason} ->
            Logger.warning("Failed to create episode from season data",
              media_item_id: media_item.id,
              season: season_number,
              episode: episode_data.episode_number,
              reason: reason
            )
        end
      end
    end)
  rescue
    error ->
      Logger.error("Exception while creating episodes from season data",
        media_item_id: media_item.id,
        error: Exception.message(error)
      )
  end

  # Parses an air date string
  defp parse_air_date(nil), do: nil
  defp parse_air_date(""), do: nil

  defp parse_air_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_air_date(_), do: nil

  # Extract technical metadata from file and update the media_file record
  defp extract_and_update_file_metadata(media_file, file_info) do
    # Parse filename for fallback metadata
    filename_metadata = FileParser.parse(Path.basename(file_info.path))

    # Extract technical metadata from the actual file using FFprobe
    file_metadata =
      case FileAnalyzer.analyze(file_info.path) do
        {:ok, metadata} ->
          Logger.debug("Extracted file metadata via FFprobe",
            path: file_info.path,
            resolution: metadata.resolution,
            codec: metadata.codec
          )

          metadata

        {:error, reason} ->
          Logger.debug("Failed to analyze file with FFprobe, using filename metadata only",
            path: file_info.path,
            reason: reason
          )

          # Continue with empty metadata - we'll use filename fallback below
          %{
            resolution: nil,
            codec: nil,
            audio_codec: nil,
            bitrate: nil,
            hdr_format: nil
          }
      end

    # Merge metadata: prefer actual file metadata, fall back to filename parsing
    update_attrs = %{
      resolution: file_metadata.resolution || filename_metadata.quality.resolution,
      codec: file_metadata.codec || filename_metadata.quality.codec,
      audio_codec: file_metadata.audio_codec || filename_metadata.quality.audio,
      bitrate: file_metadata.bitrate,
      hdr_format: file_metadata.hdr_format || filename_metadata.quality.hdr_format
    }

    case Library.update_media_file(media_file, update_attrs) do
      {:ok, updated_file} ->
        Logger.debug("Updated file with technical metadata",
          path: file_info.path,
          resolution: updated_file.resolution,
          codec: updated_file.codec
        )

        :ok

      {:error, changeset} ->
        Logger.warning("Failed to update file with technical metadata",
          path: file_info.path,
          errors: inspect(changeset.errors)
        )

        :error
    end
  rescue
    error ->
      Logger.error("Exception while extracting file metadata",
        path: file_info.path,
        error: Exception.message(error)
      )

      :error
  end
end
