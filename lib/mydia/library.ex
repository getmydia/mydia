defmodule Mydia.Library do
  @moduledoc """
  The Library context handles media files and library management.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Library.{MediaFile, FileAnalyzer}
  alias Mydia.Library.FileParser.V2, as: FileParser

  require Logger

  @doc """
  Returns the list of media files.

  ## Options
    - `:media_item_id` - Filter by media item
    - `:episode_id` - Filter by episode
    - `:preload` - List of associations to preload
  """
  def list_media_files(opts \\ []) do
    MediaFile
    |> apply_media_file_filters(opts)
    |> maybe_preload(opts[:preload])
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
  Gets a media file by path.
  """
  def get_media_file_by_path(path, opts \\ []) do
    MediaFile
    |> where([f], f.path == ^path)
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
  """
  def create_scanned_media_file(attrs \\ %{}) do
    %MediaFile{}
    |> MediaFile.scan_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a media file.
  """
  def update_media_file(%MediaFile{} = media_file, attrs) do
    media_file
    |> MediaFile.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Marks a media file as verified.
  """
  def verify_media_file(%MediaFile{} = media_file) do
    media_file
    |> Ecto.Changeset.change(verified_at: DateTime.utc_now())
    |> Repo.update()
  end

  @doc """
  Deletes a media file.
  """
  def delete_media_file(%MediaFile{} = media_file) do
    Repo.delete(media_file)
  end

  @doc """
  Deletes the physical file from disk for a media file record.

  Returns `:ok` if the file was successfully deleted or doesn't exist,
  `{:error, reason}` if deletion failed.

  This function should be called before deleting the database record
  to ensure the file path is available.
  """
  def delete_media_file_from_disk(%MediaFile{} = media_file) do
    if File.exists?(media_file.path) do
      case File.rm(media_file.path) do
        :ok ->
          Logger.info("Deleted media file from disk", path: media_file.path)
          :ok

        {:error, reason} ->
          Logger.error("Failed to delete media file from disk",
            path: media_file.path,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    else
      # File doesn't exist, consider it a success
      Logger.debug("Media file already doesn't exist on disk", path: media_file.path)
      :ok
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
    filename = Path.basename(media_file.path)

    # Parse the filename to extract season/episode information
    parsed_info = FileParser.parse(filename)
    season = Map.get(parsed_info, :season)
    episode_numbers = Map.get(parsed_info, :episodes)

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
          # Update the media file with the episode_id
          case update_media_file(media_file, %{
                 media_item_id: nil,
                 episode_id: episode.id
               }) do
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

  @doc """
  Returns orphaned media files (files without media_item_id or episode_id).

  These files were scanned but failed to match to any media items.
  They can be safely re-matched or deleted.

  ## Options
    - `:preload` - List of associations to preload
  """
  def list_orphaned_media_files(opts \\ []) do
    MediaFile
    |> where([f], is_nil(f.media_item_id) and is_nil(f.episode_id))
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Checks if a media file is orphaned (has no parent association).
  """
  def orphaned_media_file?(%MediaFile{} = media_file) do
    is_nil(media_file.media_item_id) and is_nil(media_file.episode_id)
  end

  ## Private Functions

  defp apply_media_file_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:media_item_id, media_item_id}, query ->
        where(query, [f], f.media_item_id == ^media_item_id)

      {:episode_id, episode_id}, query ->
        where(query, [f], f.episode_id == ^episode_id)

      {:path_prefix, prefix}, query ->
        # Filter files by path prefix (for library path scans)
        like_pattern = "#{prefix}%"
        where(query, [f], like(f.path, ^like_pattern))

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

  Returns {:ok, updated_media_file} or {:error, reason}.
  """
  def refresh_file_metadata(%MediaFile{} = media_file) do
    if File.exists?(media_file.path) do
      # Parse filename for fallback metadata
      filename_metadata = FileParser.parse(Path.basename(media_file.path))

      # Analyze actual file with FFprobe
      file_metadata =
        case FileAnalyzer.analyze(media_file.path) do
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
        hdr_format: file_metadata.hdr_format || Map.get(filename_metadata.quality, :hdr_format),
        size: file_metadata.size || File.stat!(media_file.path).size,
        verified_at: DateTime.utc_now()
      }

      case update_media_file(media_file, update_attrs) do
        {:ok, updated_file} ->
          Logger.info("Refreshed file metadata",
            file_id: media_file.id,
            path: media_file.path,
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
        path: media_file.path
      )

      {:error, :file_not_found}
    end
  end

  @doc """
  Refreshes file metadata for a media file by ID.

  Returns {:ok, updated_media_file} or {:error, reason}.
  """
  def refresh_file_metadata_by_id(media_file_id) do
    media_file = get_media_file!(media_file_id)
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
        where:
          fragment("json_extract(?, '$.download_client') = ?", f.metadata, ^client_name) and
            fragment("json_extract(?, '$.download_client_id') = ?", f.metadata, ^client_id)

    Repo.exists?(query)
  end

  @doc """
  Refreshes file metadata for all media files in the library.

  This can be a long-running operation. Returns the count of successfully refreshed files.
  """
  def refresh_all_file_metadata do
    media_files = list_media_files()

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

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, []), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)
end
