defmodule Mydia.Jobs.MediaImport do
  @moduledoc """
  Background job for importing completed downloads into the media library.

  This job:
  - Moves or copies downloaded files from download client path to library path
  - Organizes files according to media type (Movies/Title/ or TV/Show/Season XX/)
  - Creates media_files records with correct associations
  - Handles conflicts and errors gracefully
  - Optionally removes download from client after successful import
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3

  require Logger
  alias Mydia.{Downloads, Library, Settings}
  alias Mydia.Downloads.Client

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"download_id" => download_id} = args}) do
    Logger.info("Starting media import", download_id: download_id)

    download = Downloads.get_download!(download_id, preload: [:media_item, :episode])

    if download.status != "completed" do
      Logger.warning("Download not completed, skipping import",
        download_id: download_id,
        status: download.status
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
        files =
          Path.wildcard(Path.join(path, "**/*"))
          |> Enum.filter(&File.regular?/1)
          |> Enum.map(fn file_path ->
            %{
              path: file_path,
              name: Path.basename(file_path),
              size: File.stat!(file_path).size
            }
          end)

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

  defp determine_library_path(download) do
    # Get library paths from settings
    library_paths = Settings.list_library_paths()

    cond do
      # TV episode
      download.episode && download.media_item ->
        # Find a library path for series
        Enum.find(library_paths, fn lp ->
          lp.type in [:series, :mixed] && lp.monitored
        end)

      # Movie
      download.media_item && download.media_item.type == "movie" ->
        # Find a library path for movies
        Enum.find(library_paths, fn lp ->
          lp.type in [:movies, :mixed] && lp.monitored
        end)

      # TV show (no specific episode)
      download.media_item && download.media_item.type == "tv_show" ->
        # Find a library path for series
        Enum.find(library_paths, fn lp ->
          lp.type in [:series, :mixed] && lp.monitored
        end)

      true ->
        # Fallback: use first monitored mixed library
        Enum.find(library_paths, fn lp ->
          lp.type == :mixed && lp.monitored
        end)
    end
  end

  defp organize_and_import_files(download, files, library_path, args) do
    # Determine destination directory structure
    dest_dir = build_destination_path(download, library_path.path)

    # Ensure destination directory exists
    File.mkdir_p!(dest_dir)

    # Filter video files only
    video_files = filter_video_files(files)

    if video_files == [] do
      Logger.warning("No video files found in download", download_id: download.id)
      {:error, :no_video_files}
    else
      # Import each file
      results =
        Enum.map(video_files, fn file ->
          import_file(file, dest_dir, download, args)
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

  defp import_file(file, dest_dir, download, args) do
    dest_path = Path.join(dest_dir, file.name)

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
          handle_file_conflict(file, dest_path, download, args)

        existing_file ->
          # File exists and is in DB - reuse it
          Logger.info("Reusing existing media file", path: dest_path)
          {:ok, existing_file}
      end
    else
      # Copy or move file
      case copy_or_move_file(file.path, dest_path, args) do
        :ok ->
          create_media_file_record(dest_path, file.size, download)

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

  defp handle_file_conflict(file, dest_path, download, args) do
    # Check if sizes match
    dest_size = File.stat!(dest_path).size

    if dest_size == file.size do
      # Files are likely identical - create DB record
      Logger.info("File sizes match, creating DB record", path: dest_path)
      create_media_file_record(dest_path, file.size, download)
    else
      # Files differ - rename new file
      new_dest = generate_unique_path(dest_path)
      Logger.info("File conflict, using unique name", new_path: new_dest)

      case copy_or_move_file(file.path, new_dest, args) do
        :ok ->
          create_media_file_record(new_dest, file.size, download)

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
    # Default to copy for safety, allow move via config
    if args["move_files"] == true do
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
    else
      case File.cp(source, dest) do
        :ok ->
          Logger.debug("Copied file", from: source, to: dest)
          :ok

        error ->
          error
      end
    end
  end

  defp create_media_file_record(path, size, download) do
    attrs = %{
      path: path,
      size: size,
      verified_at: DateTime.utc_now(),
      metadata: %{
        imported_from_download_id: download.id,
        imported_at: DateTime.utc_now()
      }
    }

    attrs =
      cond do
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
          Logger.error("Download has no media_item_id or episode_id", download_id: download.id)
          attrs
      end

    case Library.create_media_file(attrs) do
      {:ok, media_file} ->
        Logger.info("Created media file record", path: path, id: media_file.id)
        {:ok, media_file}

      {:error, changeset} ->
        Logger.error("Failed to create media file record",
          path: path,
          errors: inspect(changeset.errors)
        )

        {:error, :database_error}
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
end
