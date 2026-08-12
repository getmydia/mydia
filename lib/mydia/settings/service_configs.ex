defmodule Mydia.Settings.ServiceConfigs do
  @moduledoc false

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers

  alias Mydia.Repo

  alias Mydia.Settings.{
    DownloadClientConfig,
    IndexerConfig,
    MediaServerConfig,
    MediaServerUserLink,
    PathMappingConfig,
    PluginConfig
  }

  alias Mydia.Settings.RuntimeConfig, as: RC

  ## Download Client Configs

  def list_download_client_configs(opts \\ []) do
    # Get database configs
    db_configs =
      DownloadClientConfig
      |> maybe_preload(opts[:preload])
      |> order_by([d], desc: d.enabled, asc: d.priority, asc: d.name)
      |> Repo.all()

    # Merge with runtime config (database takes precedence by name)
    RC.merge_with_runtime_config(db_configs, &RC.get_runtime_download_clients/0, :name)
  end

  def get_download_client_config!(id, opts \\ [])

  def get_download_client_config!(id, opts) when is_binary(id) do
    if RC.runtime_id?(id) do
      case RC.parse_runtime_id(id) do
        {:ok, {:download_client, name}} ->
          # Find the runtime download client by matching the name
          runtime_clients = RC.get_runtime_download_clients()

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
      # Check if it's a valid UUID (binary_id)
      case Ecto.UUID.cast(id) do
        {:ok, uuid} ->
          # Query by UUID
          DownloadClientConfig
          |> maybe_preload(opts[:preload])
          |> Repo.get!(uuid)

        :error ->
          # Try to parse as integer ID for database lookup
          case Integer.parse(id) do
            {int_id, ""} ->
              get_download_client_config!(int_id, opts)

            _ ->
              raise "Invalid download client ID: #{id}"
          end
      end
    end
  end

  def get_download_client_config!(id, opts) when is_integer(id) do
    DownloadClientConfig
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  def create_download_client_config(attrs) do
    %DownloadClientConfig{}
    |> DownloadClientConfig.changeset(attrs)
    |> Repo.insert()
  end

  def update_download_client_config(%DownloadClientConfig{} = config, attrs) do
    config
    |> DownloadClientConfig.changeset(attrs)
    |> Repo.update()
  end

  def delete_download_client_config(%DownloadClientConfig{} = config) do
    Repo.delete(config)
  end

  ## Indexer Configs

  def list_indexer_configs(opts \\ []) do
    # Get database configs
    db_configs =
      IndexerConfig
      |> maybe_preload(opts[:preload])
      |> order_by([i], desc: i.enabled, asc: i.priority, asc: i.name)
      |> Repo.all()

    # Merge with runtime config (database takes precedence by name)
    RC.merge_with_runtime_config(db_configs, &RC.get_runtime_indexers/0, :name)
  end

  def get_indexer_config!(id, opts \\ [])

  def get_indexer_config!(id, opts) when is_binary(id) do
    if RC.runtime_id?(id) do
      case RC.parse_runtime_id(id) do
        {:ok, {:indexer, name}} ->
          # Find the runtime indexer by matching the name
          runtime_indexers = RC.get_runtime_indexers()

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
          # Try as UUID for database lookup
          case Ecto.UUID.cast(id) do
            {:ok, uuid} ->
              IndexerConfig
              |> maybe_preload(opts[:preload])
              |> Repo.get!(uuid)

            :error ->
              raise "Invalid indexer ID: #{id}"
          end
      end
    end
  end

  def get_indexer_config!(id, opts) when is_integer(id) do
    IndexerConfig
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  def create_indexer_config(attrs) do
    %IndexerConfig{}
    |> IndexerConfig.changeset(attrs)
    |> Repo.insert()
  end

  def update_indexer_config(%IndexerConfig{} = config, attrs) do
    config
    |> IndexerConfig.changeset(attrs)
    |> Repo.update()
  end

  def delete_indexer_config(%IndexerConfig{} = config) do
    Repo.delete(config)
  end

  def resolve_env_inheritance(%IndexerConfig{env_name: nil} = config), do: config
  def resolve_env_inheritance(%IndexerConfig{env_name: ""} = config), do: config

  def resolve_env_inheritance(%IndexerConfig{env_name: env_name} = config)
      when is_binary(env_name) do
    # Build environment variable names
    base_url_var = "#{env_name}_BASE_URL"
    api_key_var = "#{env_name}_API_KEY"

    # Resolve from environment, falling back to existing values
    resolved_base_url = System.get_env(base_url_var) || config.base_url
    resolved_api_key = System.get_env(api_key_var) || config.api_key

    %{config | base_url: resolved_base_url, api_key: resolved_api_key}
  end

  def list_available_env_indexers do
    System.get_env()
    |> Enum.filter(fn {key, _value} -> String.ends_with?(key, "_BASE_URL") end)
    |> Enum.map(fn {key, base_url} ->
      # Extract prefix: "PROWLARR_BASE_URL" -> "PROWLARR"
      env_name = String.replace_suffix(key, "_BASE_URL", "")
      api_key_var = "#{env_name}_API_KEY"
      has_api_key = System.get_env(api_key_var) != nil

      %{
        env_name: env_name,
        base_url: base_url,
        has_api_key: has_api_key
      }
    end)
    |> Enum.sort_by(& &1.env_name)
  end

  ## Media Server Configs

  def list_media_server_configs(opts \\ []) do
    # Get database configs
    db_configs =
      MediaServerConfig
      |> maybe_preload(opts[:preload])
      |> order_by([m], desc: m.enabled, asc: m.name)
      |> Repo.all()

    # Merge with runtime config (database takes precedence by name)
    RC.merge_with_runtime_config(db_configs, &RC.get_runtime_media_servers/0, :name)
  end

  def get_media_server_config!(id, opts \\ [])

  def get_media_server_config!(id, opts) when is_binary(id) do
    if RC.runtime_id?(id) do
      case RC.parse_runtime_id(id) do
        {:ok, {:media_server, name}} ->
          # Find the runtime media server by matching the name
          runtime_servers = RC.get_runtime_media_servers()

          case Enum.find(runtime_servers, &(&1.name == name)) do
            nil ->
              raise "Runtime media server not found: #{name}"

            server ->
              server
          end

        _ ->
          raise "Invalid runtime media server ID: #{id}"
      end
    else
      # Try to parse as integer ID for database lookup
      case Integer.parse(id) do
        {int_id, ""} ->
          get_media_server_config!(int_id, opts)

        _ ->
          # Try as UUID for database lookup
          case Ecto.UUID.cast(id) do
            {:ok, uuid} ->
              MediaServerConfig
              |> maybe_preload(opts[:preload])
              |> Repo.get!(uuid)

            :error ->
              raise "Invalid media server ID: #{id}"
          end
      end
    end
  end

  def get_media_server_config!(id, opts) when is_integer(id) do
    MediaServerConfig
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  def create_media_server_config(attrs) do
    %MediaServerConfig{}
    |> MediaServerConfig.changeset(attrs)
    |> Repo.insert()
  end

  def update_media_server_config(%MediaServerConfig{} = config, attrs) do
    config
    |> MediaServerConfig.changeset(attrs)
    |> Repo.update()
  end

  def delete_media_server_config(%MediaServerConfig{} = config) do
    Repo.delete(config)
  end

  def change_media_server_config(%MediaServerConfig{} = config, attrs \\ %{}) do
    MediaServerConfig.changeset(config, attrs)
  end

  ## Media Server User Links

  def list_media_server_user_links(media_server_config_id) do
    MediaServerUserLink
    |> where([l], l.media_server_config_id == ^media_server_config_id)
    |> order_by([l], asc: l.remote_username)
    |> Repo.all()
  end

  def get_media_server_user_link!(id) do
    Repo.get!(MediaServerUserLink, id)
  end

  def upsert_media_server_user_link(attrs) do
    %MediaServerUserLink{}
    |> MediaServerUserLink.changeset(attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :remote_user_id,
           :remote_username,
           :access_token,
           :enabled,
           :updated_at
         ]},
      conflict_target: [:media_server_config_id, :user_id]
    )
  end

  def delete_media_server_user_link(%MediaServerUserLink{} = link) do
    Repo.delete(link)
  end

  ## Plugin Configs

  def list_plugin_configs(opts \\ []) do
    db_configs =
      PluginConfig
      |> maybe_preload(opts[:preload])
      |> order_by([p], desc: p.enabled, asc: p.priority, asc: p.name)
      |> Repo.all()

    # Env/index plugins take precedence over DB rows by slug (env > DB per the
    # documented layered model). A DB upsert for an env-sourced slug therefore
    # never wins, so an env-configured plugin stays read-only (AE6). This is the
    # one place plugins intentionally diverge from the sibling service lists,
    # which use DB precedence.
    runtime = RC.get_runtime_plugins()
    runtime_slugs = MapSet.new(runtime, & &1.slug)
    db_filtered = Enum.reject(db_configs, &MapSet.member?(runtime_slugs, &1.slug))
    runtime ++ db_filtered
  end

  def get_plugin_config!(id, opts \\ [])

  def get_plugin_config!(id, opts) when is_binary(id) do
    if RC.runtime_id?(id) do
      case RC.parse_runtime_id(id) do
        {:ok, {:plugin, slug}} ->
          case Enum.find(RC.get_runtime_plugins(), &(&1.slug == slug)) do
            nil -> raise "Runtime plugin not found: #{slug}"
            plugin -> plugin
          end

        _ ->
          raise "Invalid runtime plugin ID: #{id}"
      end
    else
      case Ecto.UUID.cast(id) do
        {:ok, uuid} ->
          PluginConfig
          |> maybe_preload(opts[:preload])
          |> Repo.get!(uuid)

        :error ->
          raise "Invalid plugin ID: #{id}"
      end
    end
  end

  @doc "Fetches a plugin config by slug (DB rows only), or nil."
  def get_plugin_config_by_slug(slug) when is_binary(slug) do
    Repo.get_by(PluginConfig, slug: slug)
  end

  @doc """
  Returns the raw DB plugin-config rows (no runtime/env merge).

  Unlike `list_plugin_configs/1`, this carries the persisted artifact and
  manifest, so it is what boot-time activation (`Mydia.Plugins.register_plugins/0`)
  iterates.
  """
  def get_db_plugin_configs do
    PluginConfig
    |> order_by([p], asc: p.priority, asc: p.name)
    |> Repo.all()
  end

  def create_plugin_config(attrs) do
    %PluginConfig{}
    |> PluginConfig.changeset(attrs)
    |> Repo.insert()
  end

  def update_plugin_config(%PluginConfig{} = config, attrs) do
    config
    |> PluginConfig.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Inserts or updates a plugin config keyed by slug (DB rows only).

  Env/index-sourced (`runtime::`) plugins are never written here — they are
  read-only overlays, so AE6's "DB upsert does not overwrite an env-sourced
  field" holds: the env value wins at merge time regardless of any DB row.
  """
  def upsert_plugin_config(%{slug: slug} = attrs) when is_binary(slug) do
    case get_plugin_config_by_slug(slug) do
      nil -> create_plugin_config(attrs)
      existing -> update_plugin_config(existing, attrs)
    end
  end

  def delete_plugin_config(%PluginConfig{} = config) do
    Repo.delete(config)
  end

  def change_plugin_config(%PluginConfig{} = config, attrs \\ %{}) do
    PluginConfig.changeset(config, attrs)
  end

  ## Path Mapping Configs

  @doc """
  Lists path mappings from both the database and env, merged (a DB row shadows an
  env entry with the same `remote_prefix`) and sorted longest-prefix-first so the
  most specific match wins at rewrite time.
  """
  def list_path_mapping_configs(opts \\ []) do
    db_configs =
      PathMappingConfig
      |> maybe_preload(opts[:preload])
      |> Repo.all()

    db_configs
    |> RC.merge_with_runtime_config(&RC.get_runtime_path_mappings/0, :remote_prefix)
    |> Enum.sort_by(&String.length(&1.remote_prefix || ""), :desc)
  end

  def get_path_mapping_config!(id, opts \\ [])

  def get_path_mapping_config!(id, opts) when is_binary(id) do
    if RC.runtime_id?(id) do
      case RC.parse_runtime_id(id) do
        {:ok, {:path_mapping, remote_prefix}} ->
          case Enum.find(RC.get_runtime_path_mappings(), &(&1.remote_prefix == remote_prefix)) do
            nil -> raise "Runtime path mapping not found: #{remote_prefix}"
            mapping -> mapping
          end

        _ ->
          raise "Invalid runtime path mapping ID: #{id}"
      end
    else
      case Ecto.UUID.cast(id) do
        {:ok, uuid} ->
          PathMappingConfig
          |> maybe_preload(opts[:preload])
          |> Repo.get!(uuid)

        :error ->
          raise "Invalid path mapping ID: #{id}"
      end
    end
  end

  def create_path_mapping_config(attrs) do
    %PathMappingConfig{}
    |> PathMappingConfig.changeset(attrs)
    |> Repo.insert()
    |> tap_reload()
  end

  def update_path_mapping_config(%PathMappingConfig{} = config, attrs) do
    config
    |> PathMappingConfig.changeset(attrs)
    |> Repo.update()
    |> tap_reload()
  end

  def delete_path_mapping_config(%PathMappingConfig{} = config) do
    config
    |> Repo.delete()
    |> tap_reload()
  end

  # Refresh the cached runtime config after a successful DB write so the new
  # mapping takes effect on the next import without an application restart.
  defp tap_reload({:ok, _} = result) do
    Mydia.Config.Loader.reload()
    result
  end

  defp tap_reload(result), do: result
end
