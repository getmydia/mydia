defmodule Mydia.Jobs.MediaImport.Discovery do
  @moduledoc false

  require Logger
  alias Mydia.Settings
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.ImportCandidates
  alias Mydia.Library.SampleDetector

  @doc false
  def get_client_info(download) do
    if download.download_client && download.download_client_id do
      # Search both database and runtime config clients
      client_config =
        Settings.list_download_client_configs()
        |> Enum.find(&(&1.name == download.download_client))

      if client_config do
        adapter = Client.Registry.lookup(client_config.type)

        %{
          adapter: adapter,
          config: build_client_config(client_config),
          client_id: download.download_client_id,
          remove_completed: Map.get(client_config, :remove_completed, false),
          download_directory: Map.get(client_config, :download_directory)
        }
      end
    end
  end

  @doc false
  def get_download_files(client_info, download) do
    case Client.get_status(client_info.adapter, client_info.config, client_info.client_id) do
      {:ok, status} ->
        resolve_status_files(status, download.id)

      {:error, error} ->
        {:error, error}
    end
  end

  # Prefer the client's explicit per-torrent file list when available. Falling
  # back to a recursive listing of `save_path` is unsafe for clients (rqbit)
  # that share one output folder across many torrents — that path is what
  # cross-contaminated series libraries on galactica.
  defp resolve_status_files(%{files: files}, download_id)
       when is_list(files) and files != [] do
    resolved =
      files
      |> Enum.map(&mapped_path(&1, download_id))
      |> Enum.flat_map(&file_entry_if_exists/1)

    case resolved do
      [] ->
        Logger.warning("Torrent file list resolved to no existing paths",
          download_id: download_id,
          listed_count: length(files)
        )

        {:error, {:scoped_files_missing, length(files)}}

      entries ->
        {:ok, entries}
    end
  end

  defp resolve_status_files(%{save_path: save_path}, download_id)
       when is_binary(save_path) and save_path != "" do
    save_path
    |> mapped_path(download_id)
    |> list_files_in_path()
  end

  defp resolve_status_files(_status, download_id) do
    Logger.warning("No save_path in status", download_id: download_id)
    {:error, :no_save_path}
  end

  defp file_entry_if_exists(path) do
    cond do
      not File.exists?(path) ->
        []

      File.dir?(path) ->
        list_files_recursive(path)

      true ->
        [
          %{
            path: path,
            name: Path.basename(path),
            size: File.stat!(path).size
          }
        ]
    end
  rescue
    _e in File.Error ->
      []
  end

  # Apply configured remote→local path mappings before touching the filesystem,
  # logging the rewrite when one applies so the original and mapped paths are
  # both visible in the import logs.
  @doc false
  def mapped_path(reported_path, download_id) do
    case Mydia.Library.PathMapping.rewrite(reported_path) do
      ^reported_path ->
        reported_path

      mapped ->
        Logger.info("Applied path mapping",
          download_id: download_id,
          reported_path: reported_path,
          mapped_path: mapped
        )

        mapped
    end
  end

  @doc false
  def list_files_in_path(path) do
    path_stat = File.stat(path)
    parent_stat = File.stat(Path.dirname(path))

    cond do
      stat_eacces?(path_stat) or stat_eacces?(parent_stat) ->
        {:error, {:path_not_accessible, path}}

      File.exists?(path) ->
        if File.dir?(path) do
          files = list_files_recursive(path)
          {:ok, files}
        else
          [
            %{
              path: path,
              name: Path.basename(path),
              size: File.stat!(path).size
            }
          ]
          |> then(&{:ok, &1})
        end

      # Parent directory is visible but the leaf is gone — a genuinely missing
      # or deleted file. Keep the existing message.
      File.exists?(Path.dirname(path)) ->
        {:error, {:path_not_found, path}}

      # Even the immediate parent isn't visible inside Mydia's filesystem — this
      # is the container volume mount-mismatch signature, not a deleted file.
      true ->
        {:error, {:path_mapping_mismatch, path}}
    end
  rescue
    _e in File.Error ->
      {:error, {:path_not_accessible, path}}
  end

  defp stat_eacces?({:error, :eacces}), do: true
  defp stat_eacces?(_), do: false

  defp list_files_recursive(dir) do
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
  end

  # The extension vocabulary lives in `ImportCandidates`, which also derives the
  # skip reasons shown to the operator on a failed import. Keeping one copy means
  # the two can never disagree.
  @doc false
  def filter_files_for_library_type(files, library_type) do
    Enum.filter(files, &ImportCandidates.importable?(&1, library_type))
  end

  @doc false
  def filter_extras_and_samples(files) do
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

  defp build_client_config(client_config) do
    case client_config.type do
      :blackhole ->
        # Blackhole uses connection_settings for folder paths
        %{
          type: :blackhole,
          connection_settings: client_config.connection_settings || %{}
        }

      :debrid ->
        # Debrid reads the provider sub-selector from
        # `connection_settings["provider"]` and the operator's bearer token
        # from `api_key`. Without these the dispatch returns :invalid_config.
        %{
          type: :debrid,
          api_key: client_config.api_key,
          download_directory: client_config.download_directory,
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
end
