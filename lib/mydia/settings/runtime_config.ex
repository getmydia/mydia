defmodule Mydia.Settings.RuntimeConfig do
  @moduledoc false

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers

  alias Mydia.Repo

  alias Mydia.Settings.{
    ConfigSetting,
    DownloadClientConfig,
    IndexerConfig,
    MediaServerConfig,
    LibraryPath
  }

  ## Configuration Settings (Database)

  def list_config_settings(opts \\ []) do
    ConfigSetting
    |> maybe_preload(opts[:preload])
    |> order_by([c], asc: c.category, asc: c.key)
    |> Repo.all()
  end

  def get_config_setting_by_key(key) do
    Repo.get_by(ConfigSetting, key: key)
  end

  def create_config_setting(attrs) do
    %ConfigSetting{}
    |> ConfigSetting.changeset(attrs)
    |> Repo.insert()
  end

  def update_config_setting(%ConfigSetting{} = config_setting, attrs) do
    config_setting
    |> ConfigSetting.changeset(attrs)
    |> Repo.update()
  end

  def delete_config_setting(%ConfigSetting{} = config_setting) do
    Repo.delete(config_setting)
  end

  ## Runtime Configuration Loading

  def load_database_config do
    try do
      config_settings = list_config_settings()
      config_map = build_config_map(config_settings)
      {:ok, config_map}
    rescue
      # Database might not be available during initial setup
      DBConnection.ConnectionError -> {:ok, %{}}
      # Catch query errors during app startup (e.g., table doesn't exist yet)
      Ecto.QueryError -> {:ok, %{}}
      # Catch SQLite-specific errors
      Exqlite.Error -> {:ok, %{}}
      # Catch Repo not started yet error during application startup
      RuntimeError -> {:ok, %{}}
    end
  end

  def get_runtime_config do
    Application.get_env(:mydia, :runtime_config, Mydia.Config.Schema.defaults())
  end

  ## Typed Getters

  def get_config(path) when is_list(path) do
    config = get_runtime_config()
    get_in(config, path_to_access_keys(path))
  end

  def get_config(path, default) when is_list(path) do
    case get_config(path) do
      nil -> default
      value -> value
    end
  end

  def get_server_config do
    get_runtime_config().server
  end

  def get_database_config do
    get_runtime_config().database
  end

  def get_auth_config do
    get_runtime_config().auth
  end

  def get_media_config do
    get_runtime_config().media
  end

  def get_metadata_config do
    case get_runtime_config() do
      %{metadata: %_{} = metadata} -> metadata
      _ -> %Mydia.Config.Schema.Metadata{}
    end
  end

  def get_downloads_config do
    get_runtime_config().downloads
  end

  def get_logging_config do
    get_runtime_config().logging
  end

  def get_oban_config do
    get_runtime_config().oban
  end

  def get_streaming_config do
    get_runtime_config().streaming
  end

  ## Runtime Config Builders

  def get_runtime_download_clients do
    runtime_config = get_runtime_config()

    if is_struct(runtime_config) and Map.has_key?(runtime_config, :download_clients) do
      runtime_config.download_clients
      |> Enum.map(&map_to_download_client_config/1)
    else
      []
    end
  end

  def get_runtime_indexers do
    runtime_config = get_runtime_config()

    if is_struct(runtime_config) and Map.has_key?(runtime_config, :indexers) do
      runtime_config.indexers
      |> Enum.map(&map_to_indexer_config/1)
    else
      []
    end
  end

  def get_runtime_media_servers do
    runtime_config = get_runtime_config()

    if is_struct(runtime_config) and Map.has_key?(runtime_config, :media_servers) do
      runtime_config.media_servers
      |> Enum.map(&map_to_media_server_config/1)
    else
      []
    end
  end

  def get_runtime_library_paths do
    runtime_config = get_runtime_config()

    # Start with new library_paths schema if available
    paths =
      if is_struct(runtime_config) and Map.has_key?(runtime_config, :library_paths) do
        runtime_config.library_paths
        |> Enum.map(&map_to_library_path/1)
      else
        []
      end

    # Add legacy movies path if configured and not already in library_paths
    paths =
      if is_struct(runtime_config) and Map.has_key?(runtime_config, :media) and
           runtime_config.media.movies_path do
        movies_path = runtime_config.media.movies_path
        movies_auto_organize = Map.get(runtime_config.media, :movies_auto_organize, false)

        # Only add if not already in library_paths
        if Enum.any?(paths, &(&1.path == movies_path)) do
          paths
        else
          [
            %LibraryPath{
              id: build_runtime_id(:library_path, movies_path),
              path: movies_path,
              type: :movies,
              monitored: true,
              scan_interval: 360,
              last_scan_at: nil,
              last_scan_status: nil,
              last_scan_error: nil,
              quality_profile_id: nil,
              updated_by_id: nil,
              auto_organize: movies_auto_organize,
              inserted_at: nil,
              updated_at: nil
            }
            | paths
          ]
        end
      else
        paths
      end

    # Add legacy TV path if configured and not already in library_paths
    paths =
      if is_struct(runtime_config) and Map.has_key?(runtime_config, :media) and
           runtime_config.media.tv_path do
        tv_path = runtime_config.media.tv_path
        tv_auto_organize = Map.get(runtime_config.media, :tv_auto_organize, false)

        # Only add if not already in library_paths
        if Enum.any?(paths, &(&1.path == tv_path)) do
          paths
        else
          [
            %LibraryPath{
              id: build_runtime_id(:library_path, tv_path),
              path: tv_path,
              type: :series,
              monitored: true,
              scan_interval: 360,
              last_scan_at: nil,
              last_scan_status: nil,
              last_scan_error: nil,
              quality_profile_id: nil,
              updated_by_id: nil,
              auto_organize: tv_auto_organize,
              inserted_at: nil,
              updated_at: nil
            }
            | paths
          ]
        end
      else
        paths
      end

    paths
  end

  ## Runtime ID Helpers (public, used by other sub-modules)

  def runtime_config?(%{id: id}) when is_binary(id) do
    String.starts_with?(id, "runtime::")
  end

  def runtime_config?(_), do: false

  def runtime_id?(id) when is_binary(id) do
    String.starts_with?(id, "runtime::")
  end

  def runtime_id?(_), do: false

  def parse_runtime_id("runtime::" <> rest) do
    case String.split(rest, "::", parts: 2) do
      [type_str, key] ->
        type = String.to_existing_atom(type_str)
        {:ok, {type, key}}

      _ ->
        :error
    end
  rescue
    ArgumentError ->
      # String.to_existing_atom raises if atom doesn't exist
      :error
  end

  def parse_runtime_id(_), do: :error

  def build_runtime_id(type, key) when is_atom(type) and is_binary(key) do
    "runtime::#{type}::#{key}"
  end

  ## Merge Helper (public, used by other sub-modules)

  @doc false
  def merge_with_runtime_config(db_records, runtime_getter, merge_key) do
    # Get runtime config items
    runtime_items = runtime_getter.()

    # Create MapSet of database keys for efficient deduplication
    db_keys = MapSet.new(db_records, &Map.get(&1, merge_key))

    # Filter runtime items to exclude those already in database
    runtime_items_filtered =
      Enum.reject(runtime_items, &MapSet.member?(db_keys, Map.get(&1, merge_key)))

    # Return merged list (database + filtered runtime)
    db_records ++ runtime_items_filtered
  end

  ## Private Functions

  defp map_to_download_client_config(map) when is_map(map) do
    name = Map.get(map, :name)

    %DownloadClientConfig{
      id: build_runtime_id(:download_client, name),
      name: name,
      type: Map.get(map, :type),
      enabled: Map.get(map, :enabled, true),
      priority: Map.get(map, :priority, 10),
      host: Map.get(map, :host),
      port: Map.get(map, :port),
      use_ssl: Map.get(map, :use_ssl, false),
      url_base: Map.get(map, :url_base),
      username: Map.get(map, :username),
      password: Map.get(map, :password),
      api_key: Map.get(map, :api_key),
      category: Map.get(map, :category),
      download_directory: Map.get(map, :download_directory),
      connection_settings: Map.get(map, :connection_settings, %{}),
      updated_by_id: nil,
      inserted_at: nil,
      updated_at: nil
    }
  end

  defp map_to_indexer_config(map) when is_map(map) do
    name = Map.get(map, :name)

    %IndexerConfig{
      id: build_runtime_id(:indexer, name),
      name: name,
      type: Map.get(map, :type),
      enabled: Map.get(map, :enabled, true),
      priority: Map.get(map, :priority, 10),
      base_url: Map.get(map, :base_url),
      api_key: Map.get(map, :api_key),
      indexer_ids: Map.get(map, :indexer_ids, []),
      categories: Map.get(map, :categories, []),
      rate_limit: Map.get(map, :rate_limit),
      connection_settings: Map.get(map, :connection_settings, %{}),
      updated_by_id: nil,
      inserted_at: nil,
      updated_at: nil
    }
  end

  defp map_to_media_server_config(map) when is_map(map) do
    name = Map.get(map, :name)

    %MediaServerConfig{
      id: build_runtime_id(:media_server, name),
      name: name,
      type: Map.get(map, :type),
      enabled: Map.get(map, :enabled, true),
      url: Map.get(map, :url),
      token: Map.get(map, :token),
      connection_settings: Map.get(map, :connection_settings, %{}),
      updated_by_id: nil,
      inserted_at: nil,
      updated_at: nil
    }
  end

  defp map_to_library_path(map) when is_map(map) do
    path = Map.get(map, :path)

    %LibraryPath{
      id: build_runtime_id(:library_path, path),
      path: path,
      type: Map.get(map, :type),
      monitored: Map.get(map, :monitored, true),
      scan_interval: Map.get(map, :scan_interval, 3600),
      last_scan_at: nil,
      last_scan_status: nil,
      last_scan_error: nil,
      quality_profile_id: Map.get(map, :quality_profile_id),
      updated_by_id: nil,
      inserted_at: nil,
      updated_at: nil
    }
  end

  defp path_to_access_keys(path) do
    Enum.map(path, fn
      key when is_atom(key) -> Access.key(key)
      key -> key
    end)
  end

  defp build_config_map(config_settings) do
    Enum.reduce(config_settings, %{}, fn setting, acc ->
      # Parse the dot-notation key into path segments
      # e.g., "server.port" -> [:server, :port]
      path =
        setting.key
        |> String.split(".")
        |> Enum.map(&String.to_atom/1)

      # Parse the value based on common patterns
      parsed_value = parse_config_value(setting.value)

      # Put the value into the nested map
      put_in_path(acc, path, parsed_value)
    end)
  end

  defp parse_config_value(nil), do: nil
  defp parse_config_value(""), do: nil

  defp parse_config_value(value) when is_binary(value) do
    cond do
      # Boolean values
      value == "true" ->
        true

      value == "false" ->
        false

      # Integer values
      match?({_int, ""}, Integer.parse(value)) ->
        {int, ""} = Integer.parse(value)
        int

      # Default to string
      true ->
        value
    end
  end

  defp parse_config_value(value), do: value

  defp put_in_path(map, [key], value) do
    Map.put(map, key, value)
  end

  defp put_in_path(map, [key | rest], value) do
    nested = Map.get(map, key, %{})
    Map.put(map, key, put_in_path(nested, rest, value))
  end
end
