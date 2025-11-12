defmodule Mydia.Jobs.MediaImport do
  @moduledoc """
  Background job for importing completed downloads into the media library.

  This job:
  - Imports downloaded files using hardlinks (when on same filesystem), moves, or copies
  - Organizes files according to media type (Movies/Title/ or TV/Show/Season XX/)
  - Creates media_files records with correct associations
  - Handles conflicts and errors gracefully
  - Optionally removes download from client after successful import

  ## File Operation Priority

  When importing files, the following priority is used:
  1. Hardlink (instant, no duplicate storage) - requires same filesystem
  2. Move (when use_hardlinks=false and move_files=true)
  3. Copy (default, safest option)
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  require Logger
  alias Mydia.{Downloads, Library, Media, Settings}
  alias Mydia.Downloads.Client
  alias Mydia.Library.{FileAnalyzer, FileNamer}
  alias Mydia.Library.FileParser.V2, as: FileParser
  alias Mydia.Indexers.QualityParser

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"download_id" => download_id} = args}) do
    Logger.info("Starting media import", download_id: download_id)

    download = Downloads.get_download!(download_id, preload: [:media_item, :episode])

    if is_nil(download.completed_at) do
      Logger.warning("Download not completed, skipping import",
        download_id: download_id,
        completed_at: download.completed_at
      )

      {:ok, :skipped}
    else
      import_download(download, args)
    end
  end

  ## Private Functions

  defp import_download(download, args) do
    # Get the download client details to locate files
    client_info = get_client_info(download)

    if client_info do
      case get_download_files(client_info, download) do
        {:ok, files} when files != [] ->
          process_import(download, files, args)

        {:ok, []} ->
          Logger.error("No files found for download", download_id: download.id)
          {:error, :no_files}

        {:error, error} ->
          Logger.error("Failed to get download files",
            download_id: download.id,
            error: inspect(error)
          )

          {:error, :client_error}
      end
    else
      Logger.error("Could not get client info for download", download_id: download.id)
      {:error, :no_client}
    end
  end

  defp process_import(download, files, args) do
    # Get library path for this media type
    library_path = determine_library_path(download)

    if library_path do
      # Organize files into library structure
      case organize_and_import_files(download, files, library_path, args) do
        {:ok, imported_files} ->
          Logger.info("Successfully imported files",
            download_id: download.id,
            file_count: length(imported_files)
          )

          # Optionally remove from download client
          if args["cleanup_client"] != false do
            cleanup_download_client(download)
          end

          # Delete the download record now that import is complete
          case Downloads.delete_download(download) do
            {:ok, _deleted} ->
              Logger.info("Download record deleted after successful import",
                download_id: download.id
              )

            {:error, changeset} ->
              Logger.warning("Failed to delete download record after import",
                download_id: download.id,
                errors: inspect(changeset.errors)
              )
          end

          {:ok, :imported}

        {:error, reason} ->
          Logger.error("Failed to import files",
            download_id: download.id,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    else
      Logger.error("Could not determine library path for download", download_id: download.id)
      {:error, :no_library_path}
    end
  end

  defp get_client_info(download) do
    if download.download_client && download.download_client_id do
      runtime_config = Settings.get_runtime_config()

      if is_struct(runtime_config) and Map.has_key?(runtime_config, :download_clients) do
        client_config =
          runtime_config.download_clients
          |> Enum.find(&(&1.name == download.download_client))

        if client_config do
          adapter = get_adapter_module(client_config.type)

          %{
            adapter: adapter,
            config: build_client_config(client_config),
            client_id: download.download_client_id
          }
        end
      end
    end
  end

  defp get_download_files(client_info, download) do
    case Client.get_status(client_info.adapter, client_info.config, client_info.client_id) do
      {:ok, status} ->
        if status.save_path do
          # List files in the save path
          list_files_in_path(status.save_path)
        else
          Logger.warning("No save_path in status", download_id: download.id)
          {:ok, []}
        end

      {:error, error} ->
        {:error, error}
    end
  end

  defp list_files_in_path(path) do
    if File.exists?(path) do
      if File.dir?(path) do
        # It's a directory, list all files recursively
        # Using File.ls! instead of Path.wildcard to handle Unicode paths correctly
        files = list_files_recursive(path)

        {:ok, files}
      else
        # It's a single file
        %{
          path: path,
          name: Path.basename(path),
          size: File.stat!(path).size
        }
        |> List.wrap()
        |> then(&{:ok, &1})
      end
    else
      Logger.warning("Download path does not exist", path: path)
      {:ok, []}
    end
  end

  defp list_files_recursive(dir) do
    try do
      File.ls!(dir)
      |> Enum.flat_map(fn entry ->
        full_path = Path.join(dir, entry)

        cond do
          File.regular?(full_path) ->
            [
              %{
                path: full_path,
                name: Path.basename(full_path),
                size: File.stat!(full_path).size
              }
            ]

          File.dir?(full_path) ->
            list_files_recursive(full_path)

          true ->
            []
        end
      end)
    rescue
      e ->
        Logger.warning("Error listing files in directory",
          path: dir,
          error: Exception.message(e)
        )

        []
    end
  end

  defp determine_library_path(download) do
    # Get library paths from settings
    library_paths = Settings.list_library_paths()

    {media_type, required_types} =
      cond do
        # TV episode
        download.episode && download.media_item ->
          {"TV show", [:series, :mixed]}

        # Movie
        download.media_item && download.media_item.type == "movie" ->
          {"movie", [:movies, :mixed]}

        # TV show (no specific episode)
        download.media_item && download.media_item.type == "tv_show" ->
          {"TV show", [:series, :mixed]}

        true ->
          {"unknown", [:mixed]}
      end

    # Find compatible library path
    library_path =
      Enum.find(library_paths, fn lp ->
        lp.type in required_types && lp.monitored
      end)

    # Log warning if no compatible library found
    if is_nil(library_path) do
      Logger.warning("No compatible library path found for import",
        download_id: download.id,
        media_type: media_type,
        required_library_types: required_types,
        available_libraries:
          Enum.map(library_paths, fn lp ->
            %{path: lp.path, type: lp.type, monitored: lp.monitored}
          end)
      )
    end

    library_path
  end

  defp organize_and_import_files(download, files, library_path, args) do
    # Filter video files only
    video_files = filter_video_files(files)

    if video_files == [] do
      Logger.warning("No video files found in download", download_id: download.id)
      {:error, :no_video_files}
    else
      # Import each file - destination path is determined per-file for TV shows
      results =
        Enum.map(video_files, fn file ->
          import_file(file, download, library_path.path, args)
        end)

      # Check if all succeeded
      errors = Enum.filter(results, &match?({:error, _}, &1))

      if errors == [] do
        imported = Enum.map(results, fn {:ok, media_file} -> media_file end)
        {:ok, imported}
      else
        {:error, :partial_import}
      end
    end
  end

  defp build_destination_path(download, library_root) do
    cond do
      # TV episode
      download.episode && download.media_item ->
        title = sanitize_filename(download.media_item.title)
        season = download.episode.season_number

        Path.join([library_root, title, "Season #{String.pad_leading("#{season}", 2, "0")}"])

      # Movie
      download.media_item && download.media_item.type == "movie" ->
        title = sanitize_filename(download.media_item.title)
        year = download.media_item.year

        if year do
          Path.join([library_root, "#{title} (#{year})"])
        else
          Path.join([library_root, title])
        end

      # TV show (no specific episode) - fallback
      download.media_item && download.media_item.type == "tv_show" ->
        title = sanitize_filename(download.media_item.title)
        Path.join([library_root, title])

      # Unknown - use download title
      true ->
        title = sanitize_filename(download.title)
        Path.join([library_root, title])
    end
  end

  defp sanitize_filename(filename) do
    filename
    |> String.replace(~r/[<>:"|?*]/, "")
    |> String.replace(~r/[\/\\]/, "-")
    |> String.trim()
  end

  defp filter_video_files(files) do
    video_extensions = ~w(.mkv .mp4 .avi .mov .wmv .flv .webm .m4v .mpg .mpeg .m2ts)

    Enum.filter(files, fn file ->
      ext = Path.extname(file.name) |> String.downcase()
      ext in video_extensions
    end)
  end

  defp import_file(file, download, library_root, args) do
    # Parse filename to extract episode info for TV shows
    parsed = FileParser.parse(file.name)

    # Check if this is a season pack download
    is_season_pack = get_in(download.metadata, ["season_pack"]) == true
    season_pack_season = get_in(download.metadata, ["season_number"])

    # Determine episode and destination path
    {episode, dest_dir} =
      case {download.media_item, download.episode, parsed.type, is_season_pack} do
        # Season pack - use metadata season number as authoritative source
        {%{type: "tv_show"} = media_item, _, :tv_show, true}
        when not is_nil(season_pack_season) and not is_nil(parsed.episodes) ->
          episode_number = List.first(parsed.episodes) || 1

          Logger.debug("Processing season pack file",
            file: file.name,
            season_pack_season: season_pack_season,
            episode_number: episode_number
          )

          episode =
            Media.get_episode_by_number(
              media_item.id,
              season_pack_season,
              episode_number
            )

          episode =
            if is_nil(episode) do
              Logger.info("Episode not found, refreshing episodes for TV show",
                media_item: media_item.title,
                season: season_pack_season
              )

              # Try to refresh episodes from metadata provider
              case Media.refresh_episodes_for_tv_show(media_item) do
                {:ok, count} ->
                  Logger.info("Refreshed episodes, created #{count} episodes")

                  # Retry episode lookup
                  Media.get_episode_by_number(
                    media_item.id,
                    season_pack_season,
                    episode_number
                  )

                {:error, reason} ->
                  Logger.error("Failed to refresh episodes",
                    media_item: media_item.title,
                    reason: inspect(reason)
                  )

                  nil
              end
            else
              episode
            end

          if episode do
            Logger.debug("Found episode for season pack file",
              file: file.name,
              season: season_pack_season,
              episode: episode_number,
              episode_id: episode.id
            )

            # Build destination path using season pack metadata
            title = sanitize_filename(media_item.title)

            dest_dir =
              Path.join([
                library_root,
                title,
                "Season #{String.pad_leading("#{season_pack_season}", 2, "0")}"
              ])

            {episode, dest_dir}
          else
            Logger.warning("Episode still not found after refresh attempt",
              file: file.name,
              season: season_pack_season,
              episode: episode_number,
              media_item: media_item.title
            )

            # Build season folder path even without episode
            title = sanitize_filename(media_item.title)

            dest_dir =
              Path.join([
                library_root,
                title,
                "Season #{String.pad_leading("#{season_pack_season}", 2, "0")}"
              ])

            {nil, dest_dir}
          end

        # TV show with parsed episode info - look up the episode
        {%{type: "tv_show"} = media_item, _, :tv_show, _} when not is_nil(parsed.season) ->
          episode_number = List.first(parsed.episodes) || 1

          episode =
            Media.get_episode_by_number(
              media_item.id,
              parsed.season,
              episode_number
            )

          if episode do
            Logger.debug("Found episode for file",
              file: file.name,
              season: parsed.season,
              episode: episode_number,
              episode_id: episode.id
            )

            # Build destination path using parsed season info
            title = sanitize_filename(media_item.title)

            dest_dir =
              Path.join([
                library_root,
                title,
                "Season #{String.pad_leading("#{parsed.season}", 2, "0")}"
              ])

            {episode, dest_dir}
          else
            Logger.warning("Episode not found in database, falling back to download episode",
              file: file.name,
              season: parsed.season,
              episode: episode_number,
              media_item: media_item.title
            )

            # Fall back to download episode and default path
            dest_dir = build_destination_path(download, library_root)
            {download.episode, dest_dir}
          end

        # TV show but no parsed info - use download episode
        {%{type: "tv_show"}, episode, _, _} when not is_nil(episode) ->
          dest_dir = build_destination_path(download, library_root)
          {episode, dest_dir}

        # Movie or other - use download info
        _ ->
          dest_dir = build_destination_path(download, library_root)
          {download.episode, dest_dir}
      end

    # Ensure destination directory exists
    File.mkdir_p!(dest_dir)

    # Generate filename (optionally renamed with TRaSH format)
    final_filename = generate_filename(download, episode, file.name, args)
    dest_path = Path.join(dest_dir, final_filename)

    # Check if file already exists
    if File.exists?(dest_path) do
      Logger.warning("File already exists at destination",
        source: file.path,
        dest: dest_path
      )

      # Try to find existing media_file record
      case Library.get_media_file_by_path(dest_path) do
        nil ->
          # File exists but not in DB - this is a conflict
          handle_file_conflict(file, dest_path, episode, download, args)

        existing_file ->
          # File exists and is in DB - reuse it
          Logger.info("Reusing existing media file", path: dest_path)
          {:ok, existing_file}
      end
    else
      # Copy or move file
      case copy_or_move_file(file.path, dest_path, args) do
        :ok ->
          create_media_file_record(dest_path, file.size, episode, download)

        {:error, reason} ->
          Logger.error("Failed to copy/move file",
            source: file.path,
            dest: dest_path,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    end
  end

  defp handle_file_conflict(file, dest_path, episode, download, args) do
    # Check if sizes match
    dest_size = File.stat!(dest_path).size

    if dest_size == file.size do
      # Files are likely identical - create DB record
      Logger.info("File sizes match, creating DB record", path: dest_path)
      create_media_file_record(dest_path, file.size, episode, download)
    else
      # Files differ - rename new file
      new_dest = generate_unique_path(dest_path)
      Logger.info("File conflict, using unique name", new_path: new_dest)

      case copy_or_move_file(file.path, new_dest, args) do
        :ok ->
          create_media_file_record(new_dest, file.size, episode, download)

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp generate_unique_path(path) do
    ext = Path.extname(path)
    base = Path.basename(path, ext)
    dir = Path.dirname(path)

    timestamp = DateTime.utc_now() |> DateTime.to_unix()
    Path.join(dir, "#{base}.#{timestamp}#{ext}")
  end

  defp copy_or_move_file(source, dest, args) do
    # Priority: hardlink > move > copy
    cond do
      # Try hardlink first if enabled and on same filesystem
      args["use_hardlinks"] != false && same_filesystem?(source, dest) ->
        case File.ln(source, dest) do
          :ok ->
            Logger.debug("Created hardlink", from: source, to: dest)
            :ok

          {:error, reason} ->
            Logger.warning("Hardlink failed, falling back to copy",
              from: source,
              to: dest,
              reason: inspect(reason)
            )

            # Fallback to copy
            File.cp(source, dest)
        end

      # Move file if requested
      args["move_files"] == true ->
        case File.rename(source, dest) do
          :ok ->
            Logger.debug("Moved file", from: source, to: dest)
            :ok

          {:error, :exdev} ->
            # Cross-device move not supported, fall back to copy + delete
            with :ok <- File.cp(source, dest),
                 :ok <- File.rm(source) do
              Logger.debug("Moved file via copy+delete", from: source, to: dest)
              :ok
            end

          error ->
            error
        end

      # Default to copy
      true ->
        case File.cp(source, dest) do
          :ok ->
            Logger.debug("Copied file", from: source, to: dest)
            :ok

          error ->
            error
        end
    end
  end

  defp generate_filename(download, episode, original_filename, args) do
    # Only rename if explicitly enabled (default: false for safety)
    if args["rename_files"] == true do
      # Parse quality information from download title or original filename
      quality_info =
        QualityParser.parse(download.title || original_filename)

      media_item = download.media_item

      cond do
        # TV episode with episode info
        media_item.type == "tv_show" && not is_nil(episode) ->
          FileNamer.generate_episode_filename(
            media_item,
            episode,
            quality_info,
            original_filename
          )

        # Movie
        media_item.type == "movie" ->
          FileNamer.generate_movie_filename(
            media_item,
            quality_info,
            original_filename
          )

        # Fallback to original filename
        true ->
          original_filename
      end
    else
      # Renaming disabled - use original filename
      original_filename
    end
  end

  defp same_filesystem?(path1, path2) do
    # Use File.stat!/1 to check if both paths are on the same device
    # path2 might not exist yet, so check its parent directory
    with %{device: dev1} <- File.stat(path1),
         parent_path2 = Path.dirname(path2),
         %{device: dev2} <- File.stat(parent_path2) do
      same = dev1 == dev2

      if same do
        Logger.debug("Paths on same filesystem",
          path1: path1,
          path2: path2,
          device: dev1
        )
      else
        Logger.debug("Paths on different filesystems, hardlink not possible",
          path1: path1,
          path2: path2,
          device1: dev1,
          device2: dev2
        )
      end

      same
    else
      _ ->
        Logger.debug("Could not determine filesystem, assuming different",
          path1: path1,
          path2: path2
        )

        false
    end
  end

  defp create_media_file_record(path, size, episode, download) do
    # Extract metadata from filename first (as fallback)
    filename_metadata = FileParser.parse(Path.basename(path))

    Logger.debug("Parsed filename metadata",
      path: path,
      resolution: filename_metadata.quality.resolution,
      codec: filename_metadata.quality.codec,
      audio: filename_metadata.quality.audio
    )

    # Extract technical metadata from the actual file using FFprobe
    file_metadata =
      case FileAnalyzer.analyze(path) do
        {:ok, metadata} ->
          Logger.debug("Extracted file metadata via FFprobe",
            path: path,
            resolution: metadata.resolution,
            codec: metadata.codec,
            audio: metadata.audio_codec
          )

          metadata

        {:error, reason} ->
          Logger.warning("Failed to analyze file with FFprobe, using filename metadata only",
            path: path,
            reason: reason
          )

          # Continue with empty metadata - we'll use filename fallback below
          %{
            resolution: nil,
            codec: nil,
            audio_codec: nil,
            bitrate: nil,
            hdr_format: nil,
            size: size
          }
      end

    # Merge metadata: prefer actual file metadata, fall back to filename parsing
    attrs = %{
      path: path,
      size: file_metadata.size || size,
      resolution: file_metadata.resolution || filename_metadata.quality.resolution,
      codec: file_metadata.codec || filename_metadata.quality.codec,
      audio_codec: file_metadata.audio_codec || filename_metadata.quality.audio,
      bitrate: file_metadata.bitrate,
      hdr_format: file_metadata.hdr_format || filename_metadata.quality.hdr_format,
      verified_at: DateTime.utc_now(),
      metadata: %{
        imported_from_download_id: download.id,
        imported_at: DateTime.utc_now(),
        source: filename_metadata.quality.source,
        release_group: filename_metadata.release_group,
        download_client: download.download_client,
        download_client_id: download.download_client_id
      }
    }

    # Use the episode parameter if provided, otherwise fall back to download associations
    attrs =
      cond do
        episode && episode.id ->
          Map.merge(attrs, %{
            episode_id: episode.id,
            media_item_id: nil
          })

        download.episode_id ->
          Map.merge(attrs, %{
            episode_id: download.episode_id,
            media_item_id: nil
          })

        download.media_item_id ->
          Map.merge(attrs, %{
            media_item_id: download.media_item_id,
            episode_id: nil
          })

        true ->
          Logger.error("No episode_id or media_item_id available", download_id: download.id)
          attrs
      end

    case Library.create_media_file(attrs) do
      {:ok, media_file} ->
        Logger.info("Created media file record",
          path: path,
          id: media_file.id,
          episode_id: media_file.episode_id,
          resolution: media_file.resolution,
          codec: media_file.codec
        )

        {:ok, media_file}

      {:error, changeset} ->
        # Check if this is a library type mismatch error
        if has_library_type_mismatch_error?(changeset) do
          media_type = if episode, do: "TV show", else: "movie"

          Logger.error("Library type mismatch during import",
            path: path,
            media_type: media_type,
            download_id: download.id,
            media_item_id: download.media_item_id,
            episode_id: episode && episode.id,
            errors: format_changeset_errors(changeset)
          )

          {:error, :library_type_mismatch}
        else
          Logger.error("Failed to create media file record",
            path: path,
            errors: inspect(changeset.errors)
          )

          {:error, :database_error}
        end
    end
  end

  defp cleanup_download_client(download) do
    client_info = get_client_info(download)

    if client_info do
      case Client.remove_download(
             client_info.adapter,
             client_info.config,
             client_info.client_id
           ) do
        :ok ->
          Logger.info("Removed download from client", download_id: download.id)

        {:error, error} ->
          Logger.warning("Failed to remove download from client",
            download_id: download.id,
            error: inspect(error)
          )
      end
    end
  end

  defp get_adapter_module(:qbittorrent), do: Mydia.Downloads.Client.Qbittorrent
  defp get_adapter_module(:transmission), do: Mydia.Downloads.Client.Transmission
  defp get_adapter_module(:http), do: Mydia.Downloads.Client.HTTP
  defp get_adapter_module(_), do: nil

  defp build_client_config(client_config) do
    %{
      type: client_config.type,
      host: client_config.host,
      port: client_config.port,
      username: client_config.username,
      password: client_config.password,
      use_ssl: client_config.use_ssl || false,
      options:
        %{}
        |> maybe_put(:url_base, client_config.url_base)
        |> maybe_put(:api_key, client_config.api_key)
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, _key, ""), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  # Checks if a changeset has a library type mismatch error
  defp has_library_type_mismatch_error?(changeset) do
    Enum.any?(changeset.errors, fn {field, {message, _opts}} ->
      (field == :media_item_id or field == :episode_id) and
        (String.contains?(message, "cannot add movies to a library") or
           String.contains?(message, "cannot add TV episodes to a library"))
    end)
  end

  # Formats changeset errors for logging
  defp format_changeset_errors(changeset) do
    Enum.map(changeset.errors, fn {field, {message, _opts}} ->
      "#{field}: #{message}"
    end)
    |> Enum.join(", ")
  end
end
