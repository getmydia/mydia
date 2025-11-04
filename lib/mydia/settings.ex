defmodule Mydia.Settings do
  @moduledoc """
  The Settings context handles quality profiles and application configuration.

  ## Runtime Configuration

  The runtime configuration is loaded from multiple sources with precedence:
  1. **Environment variables** (highest priority) - Deployment-specific overrides
  2. **Database/UI settings** - Admin-managed configuration via ConfigSetting records
  3. **YAML configuration file** (config/config.yml) - File-based defaults
  4. **Schema defaults** (lowest priority) - Hard-coded defaults

  Each layer overrides the previous one, with environment variables having the
  final say. This allows admins to configure the application via the UI while
  still allowing deployment-specific overrides through environment variables.

  ### Database Configuration

  Configuration settings stored in the database use dot notation for keys:
  - `"server.port"` maps to the `:server` → `:port` config value
  - `"auth.local_enabled"` maps to `:auth` → `:local_enabled`

  Use `load_database_config/0` to retrieve all database settings as a nested map.

  Access configuration using `get_config/1` or `get_config/2`.

  ### Collection-Based Configuration Merge Pattern

  For collection-based configurations (download clients, indexers, library paths),
  this module merges database records with runtime configuration (from environment
  variables). Database records take precedence - runtime items are only included
  if they don't already exist in the database (matched by name or path).

  This pattern is implemented via the private `merge_with_runtime_config/4` helper
  and used by `list_download_client_configs/1`, `list_indexer_configs/1`, and
  `list_library_paths/1`.

  Note: `list_config_settings/0` is intentionally database-only as it's used by
  the config loader to build the configuration hierarchy.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo

  alias Mydia.Settings.{
    QualityProfile,
    ConfigSetting,
    DownloadClientConfig,
    IndexerConfig,
    LibraryPath,
    DefaultQualityProfiles
  }

  @doc """
  Returns the list of quality profiles.

  ## Options
    - `:preload` - List of associations to preload
  """
  def list_quality_profiles(opts \\ []) do
    QualityProfile
    |> maybe_preload(opts[:preload])
    |> order_by([q], asc: q.name)
    |> Repo.all()
  end

  @doc """
  Gets a single quality profile.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the quality profile does not exist.
  """
  def get_quality_profile!(id, opts \\ []) do
    QualityProfile
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a quality profile by name.
  """
  def get_quality_profile_by_name(name, opts \\ []) do
    QualityProfile
    |> where([q], q.name == ^name)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Creates a quality profile.
  """
  def create_quality_profile(attrs \\ %{}) do
    %QualityProfile{}
    |> QualityProfile.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a quality profile.
  """
  def update_quality_profile(%QualityProfile{} = quality_profile, attrs) do
    quality_profile
    |> QualityProfile.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a quality profile.
  """
  def delete_quality_profile(%QualityProfile{} = quality_profile) do
    Repo.delete(quality_profile)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking quality profile changes.
  """
  def change_quality_profile(%QualityProfile{} = quality_profile, attrs \\ %{}) do
    QualityProfile.changeset(quality_profile, attrs)
  end

  @doc """
  Ensures default quality profiles exist in the database.

  Creates default quality profiles if they don't already exist. This function
  is idempotent and safe to call multiple times - it will only create profiles
  that are missing.

  Default profiles include: Any, SD, HD-720p, HD-1080p, Full HD, and 4K/UHD.

  Returns `{:ok, created_count}` on success, where `created_count` is the number
  of profiles that were created. Returns `{:error, reason}` if the database is
  not available or there's an error creating profiles.

  ## Examples

      iex> ensure_default_quality_profiles()
      {:ok, 6}

      iex> ensure_default_quality_profiles()
      {:ok, 0}  # All profiles already exist
  """
  def ensure_default_quality_profiles do
    try do
      # Get existing profile names to avoid duplicates
      existing_names =
        QualityProfile
        |> select([q], q.name)
        |> Repo.all()
        |> MapSet.new()

      # Create missing default profiles
      created_count =
        DefaultQualityProfiles.defaults()
        |> Enum.reject(fn profile -> MapSet.member?(existing_names, profile.name) end)
        |> Enum.reduce(0, fn profile_attrs, count ->
          case create_quality_profile(profile_attrs) do
            {:ok, _profile} -> count + 1
            {:error, _changeset} -> count
          end
        end)

      {:ok, created_count}
    rescue
      # Database might not be available during initial setup
      DBConnection.ConnectionError -> {:error, :database_unavailable}
      # Catch query errors (e.g., table doesn't exist yet)
      Ecto.QueryError -> {:error, :database_unavailable}
      # Catch SQLite-specific errors
      Exqlite.Error -> {:error, :database_unavailable}
      # Catch Repo not started yet error
      RuntimeError -> {:error, :database_unavailable}
    end
  end

  ## Configuration Settings (Database)

  @doc """
  Lists all configuration settings from the database.

  Note: This function is intentionally database-only (no runtime config merge)
  as it's used by the config loader to build the configuration hierarchy.
  """
  def list_config_settings(opts \\ []) do
    ConfigSetting
    |> maybe_preload(opts[:preload])
    |> order_by([c], asc: c.category, asc: c.key)
    |> Repo.all()
  end

  @doc """
  Gets a configuration setting from the database by key.
  """
  def get_config_setting_by_key(key) do
    Repo.get_by(ConfigSetting, key: key)
  end

  @doc """
  Creates a configuration setting in the database.
  """
  def create_config_setting(attrs) do
    %ConfigSetting{}
    |> ConfigSetting.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a configuration setting in the database.
  """
  def update_config_setting(%ConfigSetting{} = config_setting, attrs) do
    config_setting
    |> ConfigSetting.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a configuration setting from the database.
  """
  def delete_config_setting(%ConfigSetting{} = config_setting) do
    Repo.delete(config_setting)
  end

  ## Download Client Configs

  @doc """
  Lists all download client configurations.

  Returns download clients from both the database and runtime configuration
  (environment variables). Runtime config clients are returned as structs
  compatible with DownloadClientConfig but without database IDs.
  """
  def list_download_client_configs(opts \\ []) do
    # Get database configs
    db_configs =
      DownloadClientConfig
      |> maybe_preload(opts[:preload])
      |> order_by([d], desc: d.enabled, asc: d.priority, asc: d.name)
      |> Repo.all()

    # Merge with runtime config (database takes precedence by name)
    merge_with_runtime_config(db_configs, &get_runtime_download_clients/0, :name, opts)
  end

  @doc """
  Gets a download client configuration by ID.

  Accepts both database IDs (integers) and runtime identifiers (strings starting
  with "runtime::download_client::"). Runtime identifiers are resolved by looking
  up the client in the runtime configuration.

  Raises `Ecto.NoResultsError` if a database ID is not found, or
  `RuntimeError` if a runtime identifier cannot be resolved.
  """
  def get_download_client_config!(id, opts \\ [])

  def get_download_client_config!(id, opts) when is_binary(id) do
    if runtime_id?(id) do
      case parse_runtime_id(id) do
        {:ok, {:download_client, name}} ->
          # Find the runtime download client by matching the name
          runtime_clients = get_runtime_download_clients()

          case Enum.find(runtime_clients, &(&1.name == name)) do
            nil ->
              raise "Runtime download client not found: #{name}"

            client ->
              client
          end

        _ ->
          raise "Invalid runtime download client ID: #{id}"
      end
    else
      # Try to parse as integer ID for database lookup
      case Integer.parse(id) do
        {int_id, ""} ->
          get_download_client_config!(int_id, opts)

        _ ->
          raise "Invalid download client ID: #{id}"
      end
    end
  end

  def get_download_client_config!(id, opts) when is_integer(id) do
    DownloadClientConfig
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Creates a download client configuration.
  """
  def create_download_client_config(attrs) do
    %DownloadClientConfig{}
    |> DownloadClientConfig.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a download client configuration.
  """
  def update_download_client_config(%DownloadClientConfig{} = config, attrs) do
    config
    |> DownloadClientConfig.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a download client configuration.
  """
  def delete_download_client_config(%DownloadClientConfig{} = config) do
    Repo.delete(config)
  end

  ## Indexer Configs

  @doc """
  Lists all indexer configurations.

  Returns indexers from both the database and runtime configuration
  (environment variables). Runtime config indexers are returned as structs
  compatible with IndexerConfig but without database IDs.
  """
  def list_indexer_configs(opts \\ []) do
    # Get database configs
    db_configs =
      IndexerConfig
      |> maybe_preload(opts[:preload])
      |> order_by([i], desc: i.enabled, asc: i.priority, asc: i.name)
      |> Repo.all()

    # Merge with runtime config (database takes precedence by name)
    merge_with_runtime_config(db_configs, &get_runtime_indexers/0, :name, opts)
  end

  @doc """
  Gets an indexer configuration by ID.

  Accepts both database IDs (integers) and runtime identifiers (strings starting
  with "runtime::indexer::"). Runtime identifiers are resolved by looking
  up the indexer in the runtime configuration.

  Raises `Ecto.NoResultsError` if a database ID is not found, or
  `RuntimeError` if a runtime identifier cannot be resolved.
  """
  def get_indexer_config!(id, opts \\ [])

  def get_indexer_config!(id, opts) when is_binary(id) do
    if runtime_id?(id) do
      case parse_runtime_id(id) do
        {:ok, {:indexer, name}} ->
          # Find the runtime indexer by matching the name
          runtime_indexers = get_runtime_indexers()

          case Enum.find(runtime_indexers, &(&1.name == name)) do
            nil ->
              raise "Runtime indexer not found: #{name}"

            indexer ->
              indexer
          end

        _ ->
          raise "Invalid runtime indexer ID: #{id}"
      end
    else
      # Try to parse as integer ID for database lookup
      case Integer.parse(id) do
        {int_id, ""} ->
          get_indexer_config!(int_id, opts)

        _ ->
          raise "Invalid indexer ID: #{id}"
      end
    end
  end

  def get_indexer_config!(id, opts) when is_integer(id) do
    IndexerConfig
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Creates an indexer configuration.
  """
  def create_indexer_config(attrs) do
    %IndexerConfig{}
    |> IndexerConfig.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an indexer configuration.
  """
  def update_indexer_config(%IndexerConfig{} = config, attrs) do
    config
    |> IndexerConfig.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an indexer configuration.
  """
  def delete_indexer_config(%IndexerConfig{} = config) do
    Repo.delete(config)
  end

  ## Library Paths

  @doc """
  Lists all library paths.

  Returns library paths from both the database and runtime configuration
  (environment variables). Runtime config paths are returned as structs
  compatible with LibraryPath but without database IDs.
  """
  def list_library_paths(opts \\ []) do
    # Get database library paths
    db_paths =
      LibraryPath
      |> maybe_preload(opts[:preload])
      |> order_by([l], desc: l.monitored, asc: l.path)
      |> Repo.all()

    # Merge with runtime config (database takes precedence by path)
    merge_with_runtime_config(db_paths, &get_runtime_library_paths/0, :path, opts)
  end

  @doc """
  Gets a library path by ID.

  Accepts both database IDs (integers) and runtime identifiers (strings starting
  with "runtime::library_path::"). Runtime identifiers are resolved by looking
  up the path in the runtime configuration.

  Raises `Ecto.NoResultsError` if a database ID is not found, or
  `RuntimeError` if a runtime identifier cannot be resolved.
  """
  def get_library_path!(id, opts \\ [])

  def get_library_path!(id, opts) when is_binary(id) do
    if runtime_id?(id) do
      case parse_runtime_id(id) do
        {:ok, {:library_path, path}} ->
          # Find the runtime library path by matching the path
          runtime_paths = get_runtime_library_paths()

          case Enum.find(runtime_paths, &(&1.path == path)) do
            nil ->
              raise "Runtime library path not found: #{path}"

            library_path ->
              library_path
          end

        _ ->
          raise "Invalid runtime library path ID: #{id}"
      end
    else
      # Try to parse as integer ID for database lookup
      case Integer.parse(id) do
        {int_id, ""} ->
          get_library_path!(int_id, opts)

        _ ->
          raise "Invalid library path ID: #{id}"
      end
    end
  end

  def get_library_path!(id, opts) when is_integer(id) do
    LibraryPath
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Creates a library path.
  """
  def create_library_path(attrs) do
    %LibraryPath{}
    |> LibraryPath.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates a library path.
  """
  def update_library_path(%LibraryPath{} = library_path, attrs) do
    library_path
    |> LibraryPath.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes a library path.
  """
  def delete_library_path(%LibraryPath{} = library_path) do
    Repo.delete(library_path)
  end

  ## Runtime Configuration Functions

  @doc """
  Loads database configuration settings and converts them to a nested map structure.

  Converts flat ConfigSetting records (e.g., key: "server.port", value: "8080")
  into a nested map structure (e.g., %{server: %{port: 8080}}).

  Returns `{:ok, config_map}` where config_map is a nested map, or
  `{:ok, %{}}` if the database is unavailable.
  """
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

  @doc """
  Gets the runtime configuration.

  Returns the full configuration struct loaded at application startup.
  """
  def get_runtime_config do
    Application.get_env(:mydia, :runtime_config, Mydia.Config.Schema.defaults())
  end

  @doc """
  Gets download clients from the runtime configuration.

  Converts runtime config download client maps to DownloadClientConfig structs
  for compatibility with the rest of the application. These structs have stable
  runtime identifiers instead of database IDs (format: "runtime::download_client::name").
  """
  def get_runtime_download_clients do
    runtime_config = get_runtime_config()

    if is_struct(runtime_config) and Map.has_key?(runtime_config, :download_clients) do
      runtime_config.download_clients
      |> Enum.map(&map_to_download_client_config/1)
    else
      []
    end
  end

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

  @doc """
  Gets indexers from the runtime configuration.

  Converts runtime config indexer maps to IndexerConfig structs
  for compatibility with the rest of the application. These structs have stable
  runtime identifiers instead of database IDs (format: "runtime::indexer::name").
  """
  def get_runtime_indexers do
    runtime_config = get_runtime_config()

    if is_struct(runtime_config) and Map.has_key?(runtime_config, :indexers) do
      runtime_config.indexers
      |> Enum.map(&map_to_indexer_config/1)
    else
      []
    end
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

  @doc """
  Gets library paths from the runtime configuration.

  Converts runtime config media paths (MOVIES_PATH, TV_PATH) to LibraryPath structs
  for compatibility with the rest of the application. These structs have stable
  runtime identifiers instead of database IDs (format: "runtime::library_path::/path/to/media").
  """
  def get_runtime_library_paths do
    runtime_config = get_runtime_config()

    paths = []

    # Add movies path if configured
    paths =
      if is_struct(runtime_config) and Map.has_key?(runtime_config, :media) and
           runtime_config.media.movies_path do
        movies_path = runtime_config.media.movies_path

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
            inserted_at: nil,
            updated_at: nil
          }
          | paths
        ]
      else
        paths
      end

    # Add TV path if configured
    paths =
      if is_struct(runtime_config) and Map.has_key?(runtime_config, :media) and
           runtime_config.media.tv_path do
        tv_path = runtime_config.media.tv_path

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
            inserted_at: nil,
            updated_at: nil
          }
          | paths
        ]
      else
        paths
      end

    paths
  end

  @doc """
  Gets a configuration value by path.

  ## Examples

      iex> get_config([:server, :port])
      4000

      iex> get_config([:database, :path])
      "mydia_dev.db"

      iex> get_config([:auth, :oidc_enabled])
      false
  """
  def get_config(path) when is_list(path) do
    config = get_runtime_config()
    get_in(config, path_to_access_keys(path))
  end

  @doc """
  Gets a configuration value by path with a default.

  ## Examples

      iex> get_config([:server, :port], 8080)
      4000

      iex> get_config([:nonexistent, :key], "default")
      "default"
  """
  def get_config(path, default) when is_list(path) do
    case get_config(path) do
      nil -> default
      value -> value
    end
  end

  @doc """
  Gets server configuration.
  """
  def get_server_config do
    get_runtime_config().server
  end

  @doc """
  Gets database configuration.
  """
  def get_database_config do
    get_runtime_config().database
  end

  @doc """
  Gets authentication configuration.
  """
  def get_auth_config do
    get_runtime_config().auth
  end

  @doc """
  Gets media configuration.
  """
  def get_media_config do
    get_runtime_config().media
  end

  @doc """
  Gets downloads configuration.
  """
  def get_downloads_config do
    get_runtime_config().downloads
  end

  @doc """
  Gets logging configuration.
  """
  def get_logging_config do
    get_runtime_config().logging
  end

  @doc """
  Gets Oban configuration.
  """
  def get_oban_config do
    get_runtime_config().oban
  end

  ## Private Functions

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, []), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  # Merges database records with runtime configuration items.
  #
  # Database records take precedence - runtime items are only included if they
  # don't already exist in the database (matched by the specified merge_key).
  #
  # ## Parameters
  #   - db_records: List of database records
  #   - runtime_getter: Zero-arity function that returns runtime config items
  #   - merge_key: Atom key to use for deduplication (:name, :path, etc.)
  #   - _opts: Reserved for future options (currently unused)
  #
  # ## Returns
  #   Combined list of database records + filtered runtime items
  defp merge_with_runtime_config(db_records, runtime_getter, merge_key, _opts) do
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

  ## Runtime ID Helpers

  # Builds a stable runtime identifier for a runtime config item.
  #
  # Format: "runtime::{type}::{key}"
  # Examples:
  #   - "runtime::library_path::/media/movies"
  #   - "runtime::download_client::qbittorrent"
  #   - "runtime::indexer::prowlarr"
  defp build_runtime_id(type, key) when is_atom(type) and is_binary(key) do
    "runtime::#{type}::#{key}"
  end

  # Parses a runtime identifier into its type and key components.
  #
  # Returns {:ok, {type, key}} or :error
  defp parse_runtime_id("runtime::" <> rest) do
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

  defp parse_runtime_id(_), do: :error

  # Checks if an ID is a runtime identifier
  defp runtime_id?(id) when is_binary(id) do
    String.starts_with?(id, "runtime::")
  end

  defp runtime_id?(_), do: false
end
