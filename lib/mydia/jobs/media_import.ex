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
    max_attempts: 1000

  require Logger
  alias Mydia.{Downloads, Library, Media, Settings}
  alias Mydia.Downloads.Client
  alias Mydia.Library.{FileAnalyzer, FileNamer, FileOrganizer, SampleDetector}
  alias Mydia.Library.FileParser.V2, as: FileParser
  alias Mydia.Indexers.QualityParser
  alias Mydia.MediaServer.Notifier, as: MediaServerNotifier
  alias Mydia.Metadata.NfoWriter
  alias Mydia.Settings.LibraryPath

  defmodule Args do
    @moduledoc false
    defstruct [
      :download_id,
      :target_files,
      :save_path,
      snooze_count: 0,
      use_hardlinks: true,
      move_files: false,
      rename_files: false
    ]

    @type t :: %__MODULE__{
            download_id: String.t() | nil,
            target_files: [map()] | nil,
            save_path: String.t() | nil,
            snooze_count: integer(),
            use_hardlinks: boolean(),
            move_files: boolean(),
            rename_files: boolean()
          }

    def parse(%{"download_id" => download_id} = raw) do
      %__MODULE__{
        download_id: download_id,
        target_files: Map.get(raw, "target_files"),
        save_path: Map.get(raw, "save_path"),
        snooze_count: Map.get(raw, "snooze_count", 0),
        use_hardlinks: Map.get(raw, "use_hardlinks", true) != false,
        move_files: Map.get(raw, "move_files", false) == true,
        rename_files: Map.get(raw, "rename_files", false) == true
      }
    end
  end

  # Exponential backoff schedule in seconds
  # 1 min, 5 min, 15 min, 1 hour, 4 hours, 12 hours, 24 hours, then 24 hours indefinitely
  @backoff_schedule [60, 300, 900, 3600, 14_400, 43_200, 86_400]

  # Snooze settings for waiting on incomplete downloads
  # 5 minutes between snoozes, max 12 snoozes (1 hour total)
  @snooze_interval_seconds 300
  @max_snooze_count 12

  @spec perform(Oban.Job.t()) :: :ok | {:ok, term()} | {:error, term()} | {:snooze, pos_integer()}
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"download_id" => _} = raw_args, attempt: attempt}) do
    args = Args.parse(raw_args)
    download_id = args.download_id

    Logger.info("Starting media import",
      download_id: download_id,
      attempt: attempt
    )

    download =
      Downloads.get_download!(download_id, preload: [:media_item, :episode, :library_path])

    if is_nil(download.completed_at) do
      # Download not yet completed - use snooze mechanism instead of returning ok
      snooze_count = args.snooze_count

      if snooze_count >= @max_snooze_count do
        # Hit max snooze count - mark as failed so it appears in Issues tab
        Logger.warning(
          "Download not completed after #{snooze_count} snoozes (~1 hour), marking as failed",
          download_id: download_id,
          snooze_count: snooze_count
        )

        handle_import_failure(download, :download_not_completed, attempt)
        {:error, :download_not_completed}
      else
        Logger.info("Download not completed, scheduling retry import job",
          download_id: download_id,
          snooze_count: snooze_count + 1,
          max_snooze_count: @max_snooze_count,
          next_check_in_seconds: @snooze_interval_seconds
        )

        # Schedule a new job with incremented snooze count
        # We can't use {:snooze, seconds} because it doesn't update args
        schedule_snooze_retry(download_id, snooze_count + 1, raw_args)
        {:ok, :waiting_for_completion}
      end
    else
      case import_download(download, args) do
        {:ok, result} ->
          # Success - clear any retry metadata
          clear_retry_metadata(download)
          {:ok, result}

        {:error, reason} = error ->
          # Failure - update retry metadata and schedule next retry
          handle_import_failure(download, reason, attempt)
          error
      end
    end
  end

  @impl Oban.Worker
  def backoff(%Oban.Job{attempt: attempt}) do
    # Calculate backoff time based on attempt number
    backoff_seconds = calculate_backoff(attempt)

    Logger.info("Scheduling import retry",
      attempt: attempt,
      backoff_seconds: backoff_seconds,
      next_retry: DateTime.add(DateTime.utc_now(), backoff_seconds, :second)
    )

    backoff_seconds
  end

  ## Private Functions

  defp import_download(download, %Args{target_files: target_files} = args)
       when is_list(target_files) and target_files != [] do
    # Re-import specific files (from resolved file mappings)
    # target_files is a list of %{"path" => path, "episode_id" => id}
    process_targeted_import(download, target_files, args)
  end

  defp import_download(download, %Args{save_path: save_path} = args)
       when is_binary(save_path) and save_path != "" do
    # Use persisted save_path directly — avoids re-fetching from client
    # (Usenet items leave client history fast, so re-fetch often fails)
    case list_files_in_path(save_path) do
      {:ok, files} when files != [] ->
        process_import(download, files, args)

      {:ok, []} ->
        Logger.warning("No files at persisted save_path, falling back to client re-fetch",
          download_id: download.id,
          save_path: save_path
        )

        import_download_via_client(download, args)
    end
  end

  defp import_download(download, args) do
    import_download_via_client(download, args)
  end

  defp import_download_via_client(download, args) do
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
      # Apply library path's auto_rename setting at execution time
      args = if library_path.auto_rename, do: %{args | rename_files: true}, else: args

      # Organize files into library structure
      case organize_and_import_files(download, files, library_path, args) do
        {:ok, imported_files} ->
          Logger.info("Successfully imported files",
            download_id: download.id,
            file_count: length(imported_files)
          )

          # Reload download to check if it was flagged as having unresolved files
          updated_download =
            Downloads.get_download!(download.id, preload: [:media_item, :episode, :library_path])

          has_unresolved = updated_download.match_status == "unresolved_files"

          # Only mark as fully imported and cleanup if no unresolved files remain
          unless has_unresolved do
            # Check if we should remove from client based on client config
            client_info = get_client_info(download)
            should_cleanup = client_info && client_info.remove_completed

            if should_cleanup do
              Logger.info("Removing download from client (remove_completed enabled)",
                download_id: download.id,
                client: download.download_client
              )

              cleanup_download_client(download)
            else
              Logger.info("Keeping download in client for seeding (remove_completed disabled)",
                download_id: download.id,
                client: download.download_client
              )
            end

            # Mark download as imported instead of deleting
            # This allows the download to appear in the Completed tab
            case Downloads.update_download(updated_download, %{
                   imported_at: DateTime.utc_now(),
                   match_status: nil
                 }) do
              {:ok, _updated} ->
                Logger.info("Download marked as imported",
                  download_id: download.id
                )

              {:error, changeset} ->
                Logger.warning("Failed to mark download as imported",
                  download_id: download.id,
                  errors: inspect(changeset.errors)
                )
            end
          end

          # Write NFO metadata files if enabled for this library path
          if download.media_item_id do
            NfoWriter.maybe_write_nfos(download.media_item_id)
          end

          # Notify media servers (Plex, Jellyfin) to scan for new content
          # This is fire-and-forget (async) - errors won't affect import success
          MediaServerNotifier.notify_all()

          if has_unresolved do
            Logger.info("Partial import complete, unresolved files flagged",
              download_id: download.id
            )

            {:ok, :partial_import}
          else
            {:ok, :imported}
          end

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

  defp process_targeted_import(download, target_files, args) do
    # Import specific files with pre-assigned episode IDs (from resolved file mappings)
    library_path = determine_library_path(download)

    if is_nil(library_path) do
      Logger.error("Could not determine library path for targeted import",
        download_id: download.id
      )

      {:error, :no_library_path}
    else
      results =
        Enum.map(target_files, fn target ->
          path = target["path"]
          episode_id = target["episode_id"]

          if File.exists?(path) do
            episode = if episode_id, do: Media.get_episode!(episode_id), else: nil
            file = %{path: path, name: Path.basename(path), size: File.stat!(path).size}

            # Build destination path for this episode
            dest_dir =
              if episode && download.media_item do
                base_dir = build_series_base_path(download.media_item, library_path)

                Path.join(
                  base_dir,
                  "Season #{String.pad_leading("#{episode.season_number}", 2, "0")}"
                )
              else
                build_destination_path(download, library_path)
              end

            import_file_to_destination(file, episode, dest_dir, download, library_path, args)
          else
            Logger.warning("Target file no longer exists", path: path, download_id: download.id)
            {:error, :file_not_found}
          end
        end)

      errors = Enum.filter(results, &match?({:error, _}, &1))

      if errors == [] do
        # All targeted files imported — clear match_status and unresolved_files metadata
        current_metadata = download.metadata || %{}
        cleaned_metadata = Map.delete(current_metadata, "unresolved_files")

        Downloads.update_download(download, %{
          imported_at: DateTime.utc_now(),
          match_status: nil,
          metadata: cleaned_metadata
        })

        MediaServerNotifier.notify_all()
        {:ok, :imported}
      else
        Logger.warning("Partial targeted import failure",
          download_id: download.id,
          error_count: length(errors)
        )

        {:error, :partial_import}
      end
    end
  end

  defp get_client_info(download) do
    if download.download_client && download.download_client_id do
      # Search both database and runtime config clients
      client_config =
        Settings.list_download_client_configs()
        |> Enum.find(&(&1.name == download.download_client))

      if client_config do
        adapter = get_adapter_module(client_config.type)

        %{
          adapter: adapter,
          config: build_client_config(client_config),
          client_id: download.download_client_id,
          remove_completed: Map.get(client_config, :remove_completed, false)
        }
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
      parent_dir = Path.dirname(path)
      parent_exists = File.exists?(parent_dir)

      {parent_entry_count, parent_entries_sample} =
        if parent_exists and File.dir?(parent_dir) do
          case File.ls(parent_dir) do
            {:ok, entries} -> {length(entries), Enum.take(entries, 20)}
            {:error, _} -> {0, []}
          end
        else
          {0, []}
        end

      Logger.warning("Download path does not exist",
        path: path,
        parent_dir: parent_dir,
        parent_exists: parent_exists,
        parent_entry_count: parent_entry_count,
        parent_entries_sample: parent_entries_sample
      )

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
    # If download has a direct library_path association (specialized libraries),
    # use that directly
    if download.library_path do
      download.library_path
    else
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
  end

  defp organize_and_import_files(download, files, library_path, args) do
    # Determine which files to import based on library type
    files_to_import = filter_files_for_library_type(files, library_path.type)

    # Filter out extras, samples, and trailers
    files_to_import = filter_extras_and_samples(files_to_import)

    if files_to_import == [] do
      Logger.warning("No importable files found in download",
        download_id: download.id,
        library_type: library_path.type
      )

      {:error, :no_importable_files}
    else
      # Import each file - destination path is determined per-file for TV shows
      results =
        Enum.map(files_to_import, fn file ->
          import_file(file, download, library_path, args)
        end)

      # Separate results into imported, unresolved, and errors
      {imported, unresolved, errors} =
        Enum.reduce(results, {[], [], []}, fn
          {:ok, media_file}, {imp, unr, err} -> {[media_file | imp], unr, err}
          {:unresolved, file_info}, {imp, unr, err} -> {imp, [file_info | unr], err}
          {:error, _} = error, {imp, unr, err} -> {imp, unr, [error | err]}
        end)

      imported = Enum.reverse(imported)
      unresolved = Enum.reverse(unresolved)

      cond do
        # All files imported successfully
        unresolved == [] and errors == [] ->
          {:ok, imported}

        # Some files imported, some unresolved (partial import)
        unresolved != [] and imported != [] ->
          flag_unresolved_files(download, unresolved)
          {:ok, imported}

        # No files imported, all unresolved
        unresolved != [] and imported == [] ->
          flag_unresolved_files(download, unresolved)
          {:error, :all_files_unresolved}

        # Errors (but no unresolved)
        true ->
          {:error, :partial_import}
      end
    end
  end

  defp flag_unresolved_files(download, unresolved_files) do
    # Store unresolved file info in metadata and set match_status
    current_metadata = download.metadata || %{}

    unresolved_data =
      Enum.map(unresolved_files, fn file_info ->
        %{
          "path" => file_info.path,
          "name" => file_info.name,
          "size" => file_info.size,
          "parsed_season" => file_info.parsed_season,
          "parsed_episode" => file_info.parsed_episode,
          "assigned_episode_id" => nil
        }
      end)

    updated_metadata = Map.put(current_metadata, "unresolved_files", unresolved_data)

    case Downloads.update_download(download, %{
           match_status: "unresolved_files",
           metadata: updated_metadata
         }) do
      {:ok, _updated} ->
        Logger.info("Flagged download with #{length(unresolved_files)} unresolved file(s)",
          download_id: download.id
        )

        Downloads.broadcast_download_update(download.id)

      {:error, changeset} ->
        Logger.warning("Failed to flag unresolved files",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )
    end
  end

  defp build_destination_path(download, library_path) when is_struct(library_path, LibraryPath) do
    # Use FileOrganizer for category-aware destination paths when auto_organize is enabled
    cond do
      # Movie with auto_organize enabled
      download.media_item && download.media_item.type == "movie" && library_path.auto_organize ->
        FileOrganizer.destination_path(download.media_item, library_path)

      # TV episode - always use show folder + season subfolder
      download.episode && download.media_item ->
        # Get base folder (potentially category-aware)
        base_folder =
          if library_path.auto_organize do
            FileOrganizer.destination_path(download.media_item, library_path)
          else
            title = sanitize_filename(download.media_item.title)
            Path.join(library_path.path, title)
          end

        season = download.episode.season_number
        Path.join(base_folder, "Season #{String.pad_leading("#{season}", 2, "0")}")

      # Movie without auto_organize
      download.media_item && download.media_item.type == "movie" ->
        title = sanitize_filename(download.media_item.title)
        year = download.media_item.year

        if year do
          Path.join([library_path.path, "#{title} (#{year})"])
        else
          Path.join([library_path.path, title])
        end

      # TV show (no specific episode) - use category-aware path if enabled
      download.media_item && download.media_item.type == "tv_show" ->
        if library_path.auto_organize do
          FileOrganizer.destination_path(download.media_item, library_path)
        else
          title = sanitize_filename(download.media_item.title)
          Path.join(library_path.path, title)
        end

      # Unknown - use download title
      true ->
        title = sanitize_filename(download.title)
        Path.join(library_path.path, title)
    end
  end

  # Legacy clause for string library_root (used internally)
  defp build_destination_path(download, library_root) when is_binary(library_root) do
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

  # Helper to build category-aware base path for TV series
  defp build_series_base_path(media_item, library_path) do
    if library_path.auto_organize do
      FileOrganizer.destination_path(media_item, library_path)
    else
      title = sanitize_filename(media_item.title)
      Path.join(library_path.path, title)
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

  # Filter files based on library type
  defp filter_files_for_library_type(files, library_type)
       when library_type in [:movies, :series, :mixed] do
    # For video libraries, only import video files
    filter_video_files(files)
  end

  defp filter_files_for_library_type(files, :music) do
    # Music file extensions
    music_extensions = ~w(.mp3 .flac .wav .aac .ogg .m4a .wma .opus .ape .alac .aiff)

    Enum.filter(files, fn file ->
      ext = Path.extname(file.name) |> String.downcase()
      ext in music_extensions
    end)
  end

  defp filter_files_for_library_type(files, :books) do
    # Ebook file extensions
    book_extensions = ~w(.epub .pdf .mobi .azw .azw3 .cbr .cbz .djvu .fb2 .lit .txt .rtf)

    Enum.filter(files, fn file ->
      ext = Path.extname(file.name) |> String.downcase()
      ext in book_extensions
    end)
  end

  defp filter_files_for_library_type(files, :adult) do
    # Adult libraries can contain video and image files
    media_extensions =
      ~w(.mkv .mp4 .avi .mov .wmv .flv .webm .m4v .jpg .jpeg .png .gif .webp .bmp .tiff)

    Enum.filter(files, fn file ->
      ext = Path.extname(file.name) |> String.downcase()
      ext in media_extensions
    end)
  end

  defp filter_files_for_library_type(files, _unknown) do
    # For unknown library types, import all files (fallback)
    files
  end

  defp filter_extras_and_samples(files) do
    Enum.reject(files, fn file ->
      if SampleDetector.skip_detection?(file.path) do
        false
      else
        detection = SampleDetector.detect(file.path)

        if SampleDetector.excluded?(detection) do
          Logger.info("Skipping extra/sample/trailer file during import",
            path: file.path,
            reason: SampleDetector.exclusion_reason(detection)
          )

          true
        else
          false
        end
      end
    end)
  end

  defp import_file(file, download, library_path, args) do
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

            # Build destination path using season pack metadata (category-aware)
            base_dir = build_series_base_path(media_item, library_path)

            dest_dir =
              Path.join(base_dir, "Season #{String.pad_leading("#{season_pack_season}", 2, "0")}")

            {episode, dest_dir}
          else
            Logger.warning("Episode still not found after refresh attempt",
              file: file.name,
              season: season_pack_season,
              episode: episode_number,
              media_item: media_item.title
            )

            # Return :unresolved instead of importing with nil episode
            {:unresolved,
             %{
               path: file.path,
               name: file.name,
               size: file.size,
               parsed_season: season_pack_season,
               parsed_episode: episode_number
             }}
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

            # Build destination path using parsed season info (category-aware)
            base_dir = build_series_base_path(media_item, library_path)

            dest_dir =
              Path.join(base_dir, "Season #{String.pad_leading("#{parsed.season}", 2, "0")}")

            {episode, dest_dir}
          else
            Logger.warning("Episode not found in database, falling back to download episode",
              file: file.name,
              season: parsed.season,
              episode: episode_number,
              media_item: media_item.title
            )

            # Fall back to download episode and default path (category-aware)
            dest_dir = build_destination_path(download, library_path)
            {download.episode, dest_dir}
          end

        # TV show but no parsed info - use download episode
        {%{type: "tv_show"}, episode, _, _} when not is_nil(episode) ->
          dest_dir = build_destination_path(download, library_path)
          {episode, dest_dir}

        # Movie or other - use download info (category-aware)
        _ ->
          dest_dir = build_destination_path(download, library_path)
          {download.episode, dest_dir}
      end

    # Handle unresolved files (season pack files where episode wasn't found)
    case {episode, dest_dir} do
      {:unresolved, file_info} ->
        {:unresolved, file_info}

      {episode, dest_dir} ->
        import_file_to_destination(file, episode, dest_dir, download, library_path, args)
    end
  end

  defp import_file_to_destination(file, episode, dest_dir, download, library_path, args) do
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
          handle_file_conflict(file, dest_path, episode, download, library_path, args)

        existing_file ->
          # File exists and is in DB - reuse it
          Logger.info("Reusing existing media file", path: dest_path)
          {:ok, existing_file}
      end
    else
      # Copy or move file
      case copy_or_move_file(file.path, dest_path, args) do
        :ok ->
          create_media_file_record(dest_path, file.size, episode, download, library_path)

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

  defp handle_file_conflict(file, dest_path, episode, download, library_path, args) do
    # Check if sizes match
    dest_size = File.stat!(dest_path).size

    if dest_size == file.size do
      # Files are likely identical - create DB record
      Logger.info("File sizes match, creating DB record", path: dest_path)
      create_media_file_record(dest_path, file.size, episode, download, library_path)
    else
      # Files differ - rename new file
      new_dest = generate_unique_path(dest_path)
      Logger.info("File conflict, using unique name", new_path: new_dest)

      case copy_or_move_file(file.path, new_dest, args) do
        :ok ->
          create_media_file_record(new_dest, file.size, episode, download, library_path)

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

  defp copy_or_move_file(source, dest, %Args{} = args) do
    # Priority: hardlink > move > copy
    cond do
      # Try hardlink first if enabled and on same filesystem
      args.use_hardlinks && same_filesystem?(source, dest) ->
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
      args.move_files ->
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

  defp generate_filename(download, episode, original_filename, %Args{} = args) do
    # Only rename if explicitly enabled (default: false for safety)
    if args.rename_files do
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

  defp create_media_file_record(path, size, episode, download, library_path) do
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

    # Calculate relative path from absolute path and library path
    relative_path = Path.relative_to(path, library_path.path)

    Logger.debug("Storing media file with relative path",
      absolute_path: path,
      library_path: library_path.path,
      relative_path: relative_path,
      library_path_id: library_path.id
    )

    # Merge metadata: prefer actual file metadata, fall back to filename parsing
    attrs = %{
      relative_path: relative_path,
      library_path_id: library_path.id,
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
    # For specialized libraries (music, books, adult), there may be no media_item/episode
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

        # Specialized library download (music, books, adult) - no media_item needed
        download.library_path_id && library_path.type in [:music, :books, :adult] ->
          Logger.debug("Creating media file for specialized library",
            library_type: library_path.type,
            download_id: download.id
          )

          Map.merge(attrs, %{
            episode_id: nil,
            media_item_id: nil
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
             client_info.client_id,
             delete_files: true
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

  defp get_adapter_module(:qbittorrent), do: Mydia.Downloads.Client.QBittorrent
  defp get_adapter_module(:transmission), do: Mydia.Downloads.Client.Transmission
  defp get_adapter_module(:rtorrent), do: Mydia.Downloads.Client.Rtorrent
  defp get_adapter_module(:blackhole), do: Mydia.Downloads.Client.Blackhole
  defp get_adapter_module(:http), do: Mydia.Downloads.Client.HTTP
  defp get_adapter_module(:sabnzbd), do: Mydia.Downloads.Client.Sabnzbd
  defp get_adapter_module(:nzbget), do: Mydia.Downloads.Client.Nzbget
  defp get_adapter_module(_), do: nil

  defp build_client_config(client_config) do
    case client_config.type do
      :blackhole ->
        # Blackhole uses connection_settings for folder paths
        %{
          type: :blackhole,
          connection_settings: client_config.connection_settings || %{}
        }

      _ ->
        # Network-based clients
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
    Enum.map_join(changeset.errors, ", ", fn {field, {message, _opts}} ->
      "#{field}: #{message}"
    end)
  end

  # Calculate exponential backoff based on attempt number
  defp calculate_backoff(attempt) do
    # Attempt is 1-indexed, but we want 0-indexed for the schedule
    index = attempt - 1

    cond do
      # For attempts within our schedule, use the configured value
      index < length(@backoff_schedule) ->
        Enum.at(@backoff_schedule, index)

      # For attempts beyond our schedule, use the last value (24 hours)
      true ->
        List.last(@backoff_schedule)
    end
  end

  # Update download record with retry metadata after a failed attempt
  defp handle_import_failure(download, reason, attempt) do
    backoff_seconds = calculate_backoff(attempt)
    next_retry_at = DateTime.add(DateTime.utc_now(), backoff_seconds, :second)

    # Format error message with actionable context
    error_message = format_import_error(reason, download)

    # Track first failure timestamp
    import_failed_at = download.import_failed_at || DateTime.utc_now()

    attrs = %{
      import_retry_count: attempt,
      import_last_error: error_message,
      import_next_retry_at: next_retry_at,
      import_failed_at: import_failed_at
    }

    case Downloads.update_download(download, attrs) do
      {:ok, _updated} ->
        Logger.warning("Import failed, will retry",
          download_id: download.id,
          attempt: attempt,
          reason: error_message,
          next_retry_at: next_retry_at,
          backoff_seconds: backoff_seconds
        )

        :ok

      {:error, changeset} ->
        Logger.error("Failed to update retry metadata",
          download_id: download.id,
          errors: inspect(changeset.errors)
        )

        :ok
    end
  end

  # Format error messages with actionable context for users
  defp format_import_error(:no_client, download) do
    client_name = download.download_client || "Unknown"

    "Download client '#{client_name}' not found in settings. " <>
      "Check Settings → Download Clients and verify the client is configured."
  end

  defp format_import_error(:client_error, download) do
    client_name = download.download_client || "Unknown"

    "Cannot connect to download client '#{client_name}'. " <>
      "Check that the client is running and accessible from the server."
  end

  defp format_import_error(:no_files, _download) do
    "No files found in download location. " <>
      "The download may have been moved, deleted, or is still extracting. " <>
      "Import will retry automatically."
  end

  defp format_import_error(:no_library_path, download) do
    media_type = get_media_type_name(download)

    "No library configured for #{media_type}. " <>
      "Add a compatible library in Settings → Libraries."
  end

  defp format_import_error(:no_importable_files, download) do
    media_type = get_media_type_name(download)

    "No importable files found for #{media_type}. " <>
      "The download may contain only non-media files (samples, NFO, etc.)."
  end

  defp format_import_error(:partial_import, _download) do
    "Some files could not be imported. " <>
      "Check library path permissions and available disk space."
  end

  defp format_import_error(:download_not_completed, download) do
    client_name = download.download_client || "Unknown"

    "Download not yet complete in '#{client_name}' after waiting ~1 hour. " <>
      "Check the download client for errors or stalled downloads."
  end

  defp format_import_error(:library_type_mismatch, download) do
    media_type = get_media_type_name(download)

    "Cannot import #{media_type} to the configured library. " <>
      "The library type doesn't match the media type (e.g., trying to add movies to a TV library)."
  end

  defp format_import_error(:database_error, _download) do
    "Database error while creating file records. " <>
      "This may be a temporary issue. Import will retry automatically."
  end

  defp format_import_error(reason, _download) when is_atom(reason) do
    # Fallback for unknown atom errors
    reason |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp format_import_error(reason, _download) when is_binary(reason) do
    reason
  end

  defp format_import_error(reason, _download) do
    inspect(reason)
  end

  # Helper to get a human-readable media type name
  defp get_media_type_name(download) do
    cond do
      download.episode && download.media_item ->
        "TV show episode"

      download.media_item && download.media_item.type == "movie" ->
        "movie"

      download.media_item && download.media_item.type == "tv_show" ->
        "TV show"

      download.library_path && download.library_path.type == :music ->
        "music"

      download.library_path && download.library_path.type == :books ->
        "book"

      download.library_path && download.library_path.type == :adult ->
        "adult content"

      true ->
        "media"
    end
  end

  # Clear retry metadata after successful import
  defp clear_retry_metadata(download) do
    # Only clear if there was a previous failure
    if download.import_failed_at do
      attrs = %{
        import_retry_count: 0,
        import_last_error: nil,
        import_next_retry_at: nil,
        import_failed_at: nil
      }

      case Downloads.update_download(download, attrs) do
        {:ok, _updated} ->
          Logger.info("Import succeeded after #{download.import_retry_count} retries",
            download_id: download.id
          )

          :ok

        {:error, changeset} ->
          Logger.warning("Failed to clear retry metadata",
            download_id: download.id,
            errors: inspect(changeset.errors)
          )

          :ok
      end
    end
  end

  # Schedule a retry job when download is not yet completed
  # Uses a new job with updated snooze_count to track how long we've been waiting
  defp schedule_snooze_retry(download_id, new_snooze_count, original_args) do
    scheduled_at = DateTime.add(DateTime.utc_now(), @snooze_interval_seconds, :second)

    # Preserve original args but update snooze_count
    new_args =
      original_args
      |> Map.put("snooze_count", new_snooze_count)

    changeset = __MODULE__.new(new_args, scheduled_at: scheduled_at)

    # Use Oban.insert if available, otherwise fall back to Repo.insert for testing
    result =
      try do
        Oban.insert(changeset)
      rescue
        RuntimeError ->
          # In testing mode without running Oban, insert directly via Repo
          Mydia.Repo.insert(changeset)
      end

    case result do
      {:ok, job} ->
        Logger.debug("Scheduled snooze retry job",
          download_id: download_id,
          job_id: job.id,
          snooze_count: new_snooze_count,
          scheduled_at: scheduled_at
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to schedule snooze retry job",
          download_id: download_id,
          reason: inspect(reason)
        )

        :error
    end
  end
end
