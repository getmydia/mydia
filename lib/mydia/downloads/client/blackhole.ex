defmodule Mydia.Downloads.Client.Blackhole do
  @moduledoc """
  Blackhole download client adapter.

  A filesystem-based "blackhole" implementation that writes .torrent files to a
  watched folder and monitors a completed folder for finished downloads. This is
  similar to Sonarr/Radarr's blackhole feature.

  ## Use Case

  Users with external blackhole-based workflows (seedboxes, external scripts) can
  use Mydia without direct torrent client integration. The external process:
  1. Watches the watch folder for new .torrent files
  2. Downloads the content
  3. Places completed downloads in the completed folder

  ## Configuration

  The adapter expects the following configuration:

      config = %{
        type: :blackhole,
        connection_settings: %{
          "watch_folder" => "/path/to/watch",
          "completed_folder" => "/path/to/completed",
          "use_category_subfolders" => true  # optional, creates movies/tv subfolders
        }
      }

  ## Operation

  - `test_connection/1`: Verifies folders exist and are accessible
  - `add_torrent/3`: Writes .torrent file to watch folder
  - `get_status/2`: Checks if download is pending (in watch) or completed
  - `list_torrents/2`: Lists pending and completed downloads
  - `remove_torrent/3`: Deletes .torrent from watch folder, optionally from completed
  - `pause_torrent/2`, `resume_torrent/2`: Not supported (external process handles this)

  ## Matching Logic

  Torrent files are matched to completed downloads by extracting the torrent name
  and looking for matching folders in the completed directory.

  ## Priority

  Priority is a **no-op** for blackhole clients: dropping a file into a
  watched folder gives us no queue to manipulate. The `:priority` option (and
  any `priority_profile` overrides on the client config) is silently ignored
  without raising. This adapter accepts the option for behaviour-parity with
  the other clients so callers don't need to special-case blackhole.
  """

  @behaviour Mydia.Downloads.Client

  @impl true
  def supported_protocols, do: [:torrent]

  alias Mydia.Downloads.Client.Error
  alias Mydia.Downloads.Client.Helpers
  alias Mydia.Downloads.Structs.{ClientInfo, DownloadStatus}
  alias Mydia.Downloads.TorrentHash

  @torrent_extension ".torrent"
  @version "1.0.0"

  @impl true
  def test_connection(config) do
    with {:ok, watch_folder, completed_folder} <- get_folder_paths(config),
         :ok <- validate_folder(watch_folder, :write),
         :ok <- validate_folder(completed_folder, :read) do
      {:ok, ClientInfo.new(version: @version, api_version: "filesystem")}
    end
  end

  @impl true
  def add_torrent(config, torrent, opts \\ []) do
    with {:ok, watch_folder, _completed_folder} <- get_folder_paths(config),
         {:ok, torrent_data, torrent_hash} <- normalize_torrent_input(torrent),
         {:ok, target_folder} <- get_target_folder(config, watch_folder, opts),
         :ok <- ensure_folder_exists(target_folder),
         {:ok, _file_path} <- write_torrent_file(target_folder, torrent_hash, torrent_data) do
      # Store metadata about this torrent for later lookup
      {:ok, torrent_hash}
    else
      {:error, %Error{} = error} -> {:error, error}
      {:error, reason} -> {:error, Error.api_error("Failed to add torrent: #{inspect(reason)}")}
    end
  end

  @impl true
  def get_status(config, client_id) do
    with {:ok, watch_folder, completed_folder} <- get_folder_paths(config) do
      # Check if torrent file exists in watch folder (pending)
      torrent_file = find_torrent_file(watch_folder, client_id)

      # Check if matching folder exists in completed folder
      completed_path = find_completed_download(completed_folder, client_id)

      cond do
        completed_path != nil ->
          # Download is completed
          {:ok, build_completed_status(client_id, completed_path)}

        torrent_file != nil ->
          # Download is still pending (external process hasn't picked it up or is still downloading)
          {:ok, build_pending_status(client_id, torrent_file)}

        true ->
          {:error, Error.not_found("Torrent not found")}
      end
    end
  end

  @impl true
  def list_torrents(config, opts \\ []) do
    with {:ok, watch_folder, completed_folder} <- get_folder_paths(config) do
      # List pending torrents (files in watch folder)
      pending = list_pending_torrents(watch_folder)

      # List completed torrents (folders in completed folder)
      completed = list_completed_downloads(completed_folder)

      # Merge and filter
      all_torrents = pending ++ completed
      filtered = apply_filters(all_torrents, opts)

      {:ok, filtered}
    end
  end

  @impl true
  def remove_torrent(config, client_id, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    with {:ok, watch_folder, completed_folder} <- get_folder_paths(config) do
      # Remove torrent file from watch folder
      torrent_file = find_torrent_file(watch_folder, client_id)

      if torrent_file do
        File.rm(torrent_file)
      end

      # Optionally remove completed download
      if delete_files do
        completed_path = find_completed_download(completed_folder, client_id)

        if completed_path do
          File.rm_rf(completed_path)
        end
      end

      :ok
    end
  end

  @impl true
  def pause_torrent(_config, _client_id) do
    {:error, Error.api_error("Pause not supported for blackhole clients")}
  end

  @impl true
  def resume_torrent(_config, _client_id) do
    {:error, Error.api_error("Resume not supported for blackhole clients")}
  end

  ## Private Functions

  defp get_folder_paths(config) do
    connection_settings = config[:connection_settings] || config.connection_settings || %{}

    watch_folder = connection_settings["watch_folder"]
    completed_folder = connection_settings["completed_folder"]

    cond do
      is_nil(watch_folder) or watch_folder == "" ->
        {:error, Error.invalid_config("Watch folder is required")}

      is_nil(completed_folder) or completed_folder == "" ->
        {:error, Error.invalid_config("Completed folder is required")}

      true ->
        {:ok, watch_folder, completed_folder}
    end
  end

  defp validate_folder(path, mode) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :directory, access: access}} ->
        case {mode, access} do
          {:read, access} when access in [:read, :read_write] ->
            :ok

          {:write, :read_write} ->
            :ok

          {:write, _} ->
            {:error, Error.invalid_config("Folder is not writable: #{path}")}

          {:read, _} ->
            {:error, Error.invalid_config("Folder is not readable: #{path}")}
        end

      {:ok, %File.Stat{type: type}} ->
        {:error, Error.invalid_config("Path is not a directory (#{type}): #{path}")}

      {:error, :enoent} ->
        {:error, Error.invalid_config("Folder does not exist: #{path}")}

      {:error, reason} ->
        {:error, Error.invalid_config("Cannot access folder: #{path} (#{reason})")}
    end
  end

  defp normalize_torrent_input({:file, file_contents}) do
    case TorrentHash.extract({:file, file_contents}) do
      {:ok, hash} ->
        {:ok, file_contents, hash}

      {:error, _} = error ->
        error
    end
  end

  defp normalize_torrent_input({:magnet, magnet_link}) do
    case TorrentHash.extract({:magnet, magnet_link}) do
      {:ok, hash} ->
        # For magnet links, we'll create a simple .magnet file instead
        # The external process should handle .magnet files
        {:ok, magnet_link, hash}

      {:error, _} = error ->
        error
    end
  end

  defp normalize_torrent_input({:url, url}) do
    case TorrentHash.extract({:url, url}) do
      {:ok, hash} ->
        # Re-download to get the file contents (TorrentHash already downloaded once)
        # This is slightly inefficient but keeps the code simple
        case Req.get(url, receive_timeout: 30_000) do
          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            {:ok, body, hash}

          {:ok, %{status: status}} ->
            {:error, Error.api_error("Failed to download torrent: HTTP #{status}")}

          {:error, reason} ->
            {:error, Error.api_error("Failed to download torrent: #{inspect(reason)}")}
        end

      {:error, _} = error ->
        error
    end
  end

  defp get_target_folder(config, base_folder, opts) do
    connection_settings = config[:connection_settings] || config.connection_settings || %{}
    # The admin form stores connection_settings as strings; YAML/env carry booleans.
    use_subfolders = connection_settings["use_category_subfolders"] in [true, "true"]

    if use_subfolders and opts[:category] do
      {:ok, Path.join(base_folder, opts[:category])}
    else
      {:ok, base_folder}
    end
  end

  defp ensure_folder_exists(folder) do
    case File.mkdir_p(folder) do
      :ok -> :ok
      {:error, reason} -> {:error, Error.api_error("Failed to create folder: #{reason}")}
    end
  end

  defp write_torrent_file(folder, torrent_hash, torrent_data) do
    # Use hash as filename to ensure uniqueness
    extension =
      if String.contains?(torrent_data, "magnet:?"), do: ".magnet", else: @torrent_extension

    filename = "#{torrent_hash}#{extension}"
    file_path = Path.join(folder, filename)

    case File.write(file_path, torrent_data) do
      :ok -> {:ok, file_path}
      {:error, reason} -> {:error, Error.api_error("Failed to write torrent file: #{reason}")}
    end
  end

  defp find_torrent_file(watch_folder, hash) do
    hash_upper = String.upcase(hash)

    case File.ls(watch_folder) do
      {:ok, files} ->
        Enum.find_value(files, fn file ->
          file_upper = String.upcase(file)

          if String.starts_with?(file_upper, hash_upper) and
               (String.ends_with?(file, @torrent_extension) or String.ends_with?(file, ".magnet")) do
            Path.join(watch_folder, file)
          end
        end)

      {:error, _} ->
        nil
    end
  end

  defp find_completed_download(completed_folder, hash) do
    hash_upper = String.upcase(hash)

    case File.ls(completed_folder) do
      {:ok, entries} ->
        Enum.find_value(entries, fn entry ->
          entry_path = Path.join(completed_folder, entry)
          entry_upper = String.upcase(entry)

          # Match by hash prefix or folder containing hash
          if File.dir?(entry_path) and String.contains?(entry_upper, hash_upper) do
            entry_path
          end
        end)

      {:error, _} ->
        nil
    end
  end

  defp list_pending_torrents(watch_folder) do
    case File.ls(watch_folder) do
      {:ok, files} ->
        files
        |> Enum.filter(fn file ->
          String.ends_with?(file, @torrent_extension) or String.ends_with?(file, ".magnet")
        end)
        |> Enum.map(fn file ->
          file_path = Path.join(watch_folder, file)
          hash = Path.basename(file, Path.extname(file))
          build_pending_status(hash, file_path)
        end)

      {:error, _} ->
        []
    end
  end

  defp list_completed_downloads(completed_folder) do
    case File.ls(completed_folder) do
      {:ok, entries} ->
        entries
        |> Enum.filter(fn entry ->
          File.dir?(Path.join(completed_folder, entry))
        end)
        |> Enum.map(fn entry ->
          entry_path = Path.join(completed_folder, entry)
          # Use folder name as hash/id
          build_completed_status(entry, entry_path)
        end)

      {:error, _} ->
        []
    end
  end

  defp build_pending_status(hash, file_path) do
    added_at =
      case File.stat(file_path, time: :posix) do
        {:ok, %{ctime: ctime}} -> Helpers.parse_timestamp_unix(ctime)
        _ -> nil
      end

    DownloadStatus.new(%{
      id: hash,
      name: Path.basename(file_path, Path.extname(file_path)),
      state: :downloading,
      progress: 0.0,
      download_speed: 0,
      upload_speed: 0,
      downloaded: 0,
      uploaded: 0,
      size: 0,
      eta: nil,
      ratio: 0.0,
      save_path: file_path,
      added_at: added_at,
      completed_at: nil
    })
  end

  defp build_completed_status(id, folder_path) do
    size = calculate_folder_size(folder_path)

    {added_at, completed_at} =
      case File.stat(folder_path, time: :posix) do
        {:ok, %{ctime: ctime, mtime: mtime}} ->
          {Helpers.parse_timestamp_unix(ctime), Helpers.parse_timestamp_unix(mtime)}

        _ ->
          {nil, nil}
      end

    DownloadStatus.new(%{
      id: id,
      name: Path.basename(folder_path),
      state: :completed,
      progress: 100.0,
      download_speed: 0,
      upload_speed: 0,
      downloaded: size,
      uploaded: 0,
      size: size,
      eta: nil,
      ratio: 0.0,
      save_path: folder_path,
      added_at: added_at,
      completed_at: completed_at
    })
  end

  defp calculate_folder_size(folder_path) do
    case File.ls(folder_path) do
      {:ok, entries} ->
        Enum.reduce(entries, 0, fn entry, acc ->
          entry_path = Path.join(folder_path, entry)

          case File.stat(entry_path) do
            {:ok, %{type: :regular, size: size}} -> acc + size
            {:ok, %{type: :directory}} -> acc + calculate_folder_size(entry_path)
            _ -> acc
          end
        end)

      {:error, _} ->
        0
    end
  end

  defp apply_filters(torrents, opts) do
    torrents
    |> filter_by_state(opts[:filter])
    |> filter_by_category(opts[:category])
  end

  defp filter_by_state(torrents, nil), do: torrents
  defp filter_by_state(torrents, :all), do: torrents

  defp filter_by_state(torrents, filter) do
    Enum.filter(torrents, fn torrent ->
      case filter do
        :downloading -> torrent.state == :downloading
        :seeding -> torrent.state == :seeding
        :paused -> torrent.state == :paused
        :completed -> torrent.state == :completed or torrent.progress >= 100.0
        :active -> torrent.download_speed > 0 || torrent.upload_speed > 0
        :inactive -> torrent.download_speed == 0 && torrent.upload_speed == 0
        _ -> true
      end
    end)
  end

  defp filter_by_category(torrents, nil), do: torrents

  defp filter_by_category(torrents, category) do
    # For blackhole, category is encoded in the folder path
    Enum.filter(torrents, fn torrent ->
      String.contains?(torrent.save_path, "/#{category}/")
    end)
  end
end
