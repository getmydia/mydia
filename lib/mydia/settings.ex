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

  Note: `list_config_settings/0` is intentionally database-only as it's used by
  the config loader to build the configuration hierarchy.
  """

  alias Mydia.Settings.{
    QualityProfile,
    ConfigSetting,
    DownloadClientConfig,
    IndexerConfig,
    MediaServerConfig,
    LibraryPath,
    PathMappingConfig,
    PluginConfig
  }

  # ── Quality Profiles ─────────────────────────────────────────────────

  @doc """
  Returns the list of quality profiles.

  ## Options
    - `:preload` - List of associations to preload
    - `:is_system` - Filter by is_system flag (true/false)
    - `:version` - Filter by version number
    - `:source_url` - Filter by source URL (exact match)
  """
  @spec list_quality_profiles(keyword()) :: [QualityProfile.t()]
  defdelegate list_quality_profiles(opts \\ []), to: Mydia.Settings.QualityProfiles

  @doc """
  Gets a single quality profile.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the quality profile does not exist.
  """
  @spec get_quality_profile!(binary(), keyword()) :: QualityProfile.t()
  defdelegate get_quality_profile!(id, opts \\ []), to: Mydia.Settings.QualityProfiles

  @doc """
  Gets a quality profile by name.
  """
  @spec get_quality_profile_by_name(String.t(), keyword()) :: QualityProfile.t() | nil
  defdelegate get_quality_profile_by_name(name, opts \\ []), to: Mydia.Settings.QualityProfiles

  @doc """
  Creates a quality profile.
  """
  @spec create_quality_profile(map()) :: {:ok, QualityProfile.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_quality_profile(attrs \\ %{}), to: Mydia.Settings.QualityProfiles

  @doc """
  Updates a quality profile.

  If quality_standards are changed, automatically triggers re-evaluation of all
  associated media files in the background to ensure scores reflect the new criteria.

  ## Options
    - `:skip_reevaluation` - Skip automatic re-evaluation (default: false)
  """
  @spec update_quality_profile(QualityProfile.t(), map(), keyword()) ::
          {:ok, QualityProfile.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_quality_profile(quality_profile, attrs, opts \\ []),
    to: Mydia.Settings.QualityProfiles

  @doc """
  Triggers background re-evaluation of all files associated with a quality profile.

  This is called automatically when a profile's quality_standards are updated.
  It spawns a background task to re-evaluate all associated files without blocking.

  ## Parameters
    - `profile_id` - ID of the profile to re-evaluate

  ## Returns
    - `:ok` - Re-evaluation task spawned successfully
  """
  @spec trigger_profile_reevaluation(binary()) :: :ok
  defdelegate trigger_profile_reevaluation(profile_id), to: Mydia.Settings.QualityProfiles

  @doc """
  Deletes a quality profile.

  Returns `{:error, :profile_in_use}` if the profile is assigned to any media items.
  """
  @spec delete_quality_profile(QualityProfile.t()) ::
          {:ok, QualityProfile.t()} | {:error, Ecto.Changeset.t()} | {:error, :profile_in_use}
  defdelegate delete_quality_profile(quality_profile), to: Mydia.Settings.QualityProfiles

  @doc """
  Checks if a quality profile is assigned to any media items.
  """
  @spec profile_in_use?(binary()) :: boolean()
  defdelegate profile_in_use?(profile_id), to: Mydia.Settings.QualityProfiles

  @doc """
  Returns the count of media items using a quality profile.
  """
  @spec count_media_items_for_profile(binary()) :: non_neg_integer()
  defdelegate count_media_items_for_profile(profile_id), to: Mydia.Settings.QualityProfiles

  @doc """
  Force deletes a quality profile, unassigning it from any media items first.

  This sets `quality_profile_id` to nil on all media items using this profile,
  then deletes the profile.
  """
  @spec force_delete_quality_profile(QualityProfile.t()) ::
          {:ok, QualityProfile.t()} | {:error, Ecto.Changeset.t()}
  defdelegate force_delete_quality_profile(quality_profile), to: Mydia.Settings.QualityProfiles

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking quality profile changes.
  """
  @spec change_quality_profile(QualityProfile.t(), map()) :: Ecto.Changeset.t()
  defdelegate change_quality_profile(quality_profile, attrs \\ %{}),
    to: Mydia.Settings.QualityProfiles

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
  @spec ensure_default_quality_profiles() ::
          {:ok, non_neg_integer()} | {:error, :database_unavailable}
  defdelegate ensure_default_quality_profiles(), to: Mydia.Settings.QualityProfiles

  @doc """
  Clones a quality profile with a new name.

  Creates a copy of the given profile with all settings preserved except:
  - New name (with " (Copy)" suffix if not provided)
  - New ID
  - is_system set to false
  - source_url set to nil
  - New timestamps

  ## Examples

      iex> clone_quality_profile(profile, "My Custom Profile")
      {:ok, %QualityProfile{name: "My Custom Profile"}}

      iex> clone_quality_profile(profile)
      {:ok, %QualityProfile{name: "HD-1080p (Copy)"}}
  """
  @spec clone_quality_profile(QualityProfile.t(), String.t() | nil) ::
          {:ok, QualityProfile.t()} | {:error, Ecto.Changeset.t()}
  defdelegate clone_quality_profile(profile, new_name \\ nil), to: Mydia.Settings.QualityProfiles

  @doc """
  Compares two quality profile versions and returns the differences.

  Returns a map with differences between the two profiles:
  - `:changed` - Map of fields that changed with {old_value, new_value}
  - `:added` - Map of fields added in profile2
  - `:removed` - Map of fields removed in profile2

  ## Examples

      iex> compare_quality_profile_versions(profile1, profile2)
      %{
        changed: %{upgrade_until_quality: {"720p", "1080p"}, version: {1, 2}},
        added: %{quality_standards: %{...}},
        removed: %{}
      }
  """
  @spec compare_quality_profile_versions(QualityProfile.t(), QualityProfile.t()) :: %{
          changed: map(),
          added: map(),
          removed: map()
        }
  defdelegate compare_quality_profile_versions(profile1, profile2),
    to: Mydia.Settings.QualityProfiles

  @doc """
  Exports a quality profile to a shareable format (JSON or YAML).

  ## Options
    - `:format` - Output format, either `:json` or `:yaml` (default: `:json`)
    - `:pretty` - Pretty print the output (default: `true`)

  ## Returns
    - `{:ok, content}` - The exported profile as a string
    - `{:error, reason}` - If the export fails

  ## Examples

      iex> export_profile(profile, format: :json)
      {:ok, "{\"schema_version\": 1, \"name\": \"HD-1080p\", ...}"}

      iex> export_profile(profile, format: :yaml)
      {:ok, "schema_version: 1\\nname: HD-1080p\\n..."}
  """
  @spec export_profile(QualityProfile.t(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  defdelegate export_profile(profile, opts \\ []), to: Mydia.Settings.QualityProfiles

  @doc """
  Imports a quality profile from a file or URL.

  ## Parameters
    - `source` - Either a file path (string), URL (string starting with http/https), or raw content
    - `opts` - Import options

  ## Options
    - `:dry_run` - If true, returns preview without saving (default: `false`)
    - `:name` - Override the profile name from the import
    - `:source_url` - Explicitly set the source URL (auto-detected for URL imports)

  ## Returns
    - `{:ok, profile}` - Successfully imported profile (or preview if dry_run)
    - `{:ok, %{action: :skip, reason: reason}}` - Skipped import with reason
    - `{:error, reason}` - If the import fails

  ## Examples

      iex> import_profile("/path/to/profile.json")
      {:ok, %QualityProfile{}}

      iex> import_profile("https://example.com/profile.yaml")
      {:ok, %QualityProfile{}}

      iex> import_profile(content, dry_run: true)
      {:ok, %{action: :create, profile: %QualityProfile{}, conflicts: []}}
  """
  @spec import_profile(String.t(), keyword()) ::
          {:ok, QualityProfile.t() | map()} | {:error, String.t()}
  defdelegate import_profile(source, opts \\ []), to: Mydia.Settings.QualityProfiles

  @doc """
  Gets the default quality profile ID from settings.

  Returns the ID as a string (UUID) if set, or nil if not configured.

  ## Examples

      iex> get_default_quality_profile_id()
      "550e8400-e29b-41d4-a716-446655440000"

      iex> get_default_quality_profile_id()
      nil
  """
  @spec get_default_quality_profile_id() :: String.t() | nil
  defdelegate get_default_quality_profile_id(), to: Mydia.Settings.QualityProfiles

  @doc """
  Gets the default quality profile struct.

  Returns the full QualityProfile struct if a default is set and exists,
  or nil if not configured or the profile doesn't exist.

  ## Examples

      iex> get_default_quality_profile()
      %QualityProfile{id: 42, name: "HD-1080p", ...}

      iex> get_default_quality_profile()
      nil
  """
  @spec get_default_quality_profile() :: QualityProfile.t() | nil
  defdelegate get_default_quality_profile(), to: Mydia.Settings.QualityProfiles

  @doc """
  Sets the default quality profile.

  Accepts a quality profile ID (string UUID or integer) or nil to clear the default.

  ## Examples

      iex> set_default_quality_profile("550e8400-e29b-41d4-a716-446655440000")
      {:ok, %ConfigSetting{}}

      iex> set_default_quality_profile(nil)
      {:ok, %ConfigSetting{}}
  """
  @spec set_default_quality_profile(String.t() | integer() | nil) ::
          {:ok, ConfigSetting.t() | nil} | {:error, Ecto.Changeset.t()}
  defdelegate set_default_quality_profile(profile_id), to: Mydia.Settings.QualityProfiles

  # ── Service Configs (Download Clients, Indexers, Media Servers) ──────

  @doc """
  Lists all download client configurations.

  Returns download clients from both the database and runtime configuration
  (environment variables). Runtime config clients are returned as structs
  compatible with DownloadClientConfig but without database IDs.
  """
  @spec list_download_client_configs(keyword()) :: [DownloadClientConfig.t()]
  defdelegate list_download_client_configs(opts \\ []), to: Mydia.Settings.ServiceConfigs

  @doc """
  Gets a download client configuration by ID.

  Accepts both database IDs (integers) and runtime identifiers (strings starting
  with "runtime::download_client::"). Runtime identifiers are resolved by looking
  up the client in the runtime configuration.

  Raises `Ecto.NoResultsError` if a database ID is not found, or
  `RuntimeError` if a runtime identifier cannot be resolved.
  """
  @spec get_download_client_config!(binary() | integer(), keyword()) :: DownloadClientConfig.t()
  defdelegate get_download_client_config!(id, opts \\ []), to: Mydia.Settings.ServiceConfigs

  @doc """
  Creates a download client configuration.
  """
  @spec create_download_client_config(map()) ::
          {:ok, DownloadClientConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_download_client_config(attrs), to: Mydia.Settings.ServiceConfigs

  @doc """
  Updates a download client configuration.
  """
  @spec update_download_client_config(DownloadClientConfig.t(), map()) ::
          {:ok, DownloadClientConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_download_client_config(config, attrs), to: Mydia.Settings.ServiceConfigs

  @doc """
  Deletes a download client configuration.
  """
  @spec delete_download_client_config(DownloadClientConfig.t()) ::
          {:ok, DownloadClientConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate delete_download_client_config(config), to: Mydia.Settings.ServiceConfigs

  # ── Path Mappings ────────────────────────────────────────────────────

  @doc """
  Lists remote→local path mappings from the database and env, merged and sorted
  longest-prefix-first.
  """
  @spec list_path_mapping_configs(keyword()) :: [PathMappingConfig.t()]
  defdelegate list_path_mapping_configs(opts \\ []), to: Mydia.Settings.ServiceConfigs

  @doc """
  Gets a path mapping by database UUID or runtime identifier.
  """
  @spec get_path_mapping_config!(binary(), keyword()) :: PathMappingConfig.t()
  defdelegate get_path_mapping_config!(id, opts \\ []), to: Mydia.Settings.ServiceConfigs

  @doc """
  Creates a path mapping and refreshes the runtime config.
  """
  @spec create_path_mapping_config(map()) ::
          {:ok, PathMappingConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_path_mapping_config(attrs), to: Mydia.Settings.ServiceConfigs

  @doc """
  Updates a path mapping and refreshes the runtime config.
  """
  @spec update_path_mapping_config(PathMappingConfig.t(), map()) ::
          {:ok, PathMappingConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_path_mapping_config(config, attrs), to: Mydia.Settings.ServiceConfigs

  @doc """
  Deletes a path mapping and refreshes the runtime config.
  """
  @spec delete_path_mapping_config(PathMappingConfig.t()) ::
          {:ok, PathMappingConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate delete_path_mapping_config(config), to: Mydia.Settings.ServiceConfigs

  @doc """
  Lists all indexer configurations.

  Returns indexers from both the database and runtime configuration
  (environment variables). Runtime config indexers are returned as structs
  compatible with IndexerConfig but without database IDs.
  """
  @spec list_indexer_configs(keyword()) :: [IndexerConfig.t()]
  defdelegate list_indexer_configs(opts \\ []), to: Mydia.Settings.ServiceConfigs

  @doc """
  Gets an indexer configuration by ID.

  Accepts both database IDs (integers) and runtime identifiers (strings starting
  with "runtime::indexer::"). Runtime identifiers are resolved by looking
  up the indexer in the runtime configuration.

  Raises `Ecto.NoResultsError` if a database ID is not found, or
  `RuntimeError` if a runtime identifier cannot be resolved.
  """
  @spec get_indexer_config!(binary() | integer(), keyword()) :: IndexerConfig.t()
  defdelegate get_indexer_config!(id, opts \\ []), to: Mydia.Settings.ServiceConfigs

  @doc """
  Creates an indexer configuration.
  """
  @spec create_indexer_config(map()) :: {:ok, IndexerConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_indexer_config(attrs), to: Mydia.Settings.ServiceConfigs

  @doc """
  Updates an indexer configuration.
  """
  @spec update_indexer_config(IndexerConfig.t(), map()) ::
          {:ok, IndexerConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_indexer_config(config, attrs), to: Mydia.Settings.ServiceConfigs

  @doc """
  Deletes an indexer configuration.
  """
  @spec delete_indexer_config(IndexerConfig.t()) ::
          {:ok, IndexerConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate delete_indexer_config(config), to: Mydia.Settings.ServiceConfigs

  @doc """
  Resolves environment variable inheritance for an indexer configuration.

  When an IndexerConfig has an `env_name` set, this function resolves the
  `base_url` and `api_key` from environment variables named `{ENV_NAME}_BASE_URL`
  and `{ENV_NAME}_API_KEY` respectively.

  This allows storing configuration like indexer_ids and priority in the database
  while keeping sensitive credentials in environment variables.

  ## Examples

      # Config with env_name: "PROWLARR"
      # Environment has PROWLARR_BASE_URL=http://prowlarr:9696 and PROWLARR_API_KEY=secret
      iex> config = %IndexerConfig{env_name: "PROWLARR", base_url: nil, api_key: nil}
      iex> resolved = resolve_env_inheritance(config)
      iex> resolved.base_url
      "http://prowlarr:9696"
      iex> resolved.api_key
      "secret"

      # Config without env_name is returned unchanged
      iex> config = %IndexerConfig{env_name: nil, base_url: "http://example.com", api_key: "key"}
      iex> resolved = resolve_env_inheritance(config)
      iex> resolved == config
      true
  """
  @spec resolve_env_inheritance(IndexerConfig.t()) :: IndexerConfig.t()
  defdelegate resolve_env_inheritance(config), to: Mydia.Settings.ServiceConfigs

  @doc """
  Lists available environment-configured indexer sources.

  Scans environment variables for patterns like `{PREFIX}_BASE_URL` and returns
  a list of available prefixes that can be used with `env_name`.

  ## Examples

      # With PROWLARR_BASE_URL and JACKETT_BASE_URL set:
      iex> list_available_env_indexers()
      [
        %{env_name: "PROWLARR", base_url: "http://prowlarr:9696", has_api_key: true},
        %{env_name: "JACKETT", base_url: "http://jackett:9117", has_api_key: true}
      ]
  """
  @spec list_available_env_indexers() :: [
          %{env_name: String.t(), base_url: String.t(), has_api_key: boolean()}
        ]
  defdelegate list_available_env_indexers(), to: Mydia.Settings.ServiceConfigs

  @doc """
  Lists all media server configurations.

  Returns media servers from both the database and runtime configuration
  (environment variables). Runtime config servers are returned as structs
  compatible with MediaServerConfig but without database IDs.
  """
  @spec list_media_server_configs(keyword()) :: [MediaServerConfig.t()]
  defdelegate list_media_server_configs(opts \\ []), to: Mydia.Settings.ServiceConfigs

  @doc """
  Gets a media server configuration by ID.

  Accepts both database IDs (integers) and runtime identifiers (strings starting
  with "runtime::media_server::"). Runtime identifiers are resolved by looking
  up the server in the runtime configuration.

  Raises `Ecto.NoResultsError` if a database ID is not found, or
  `RuntimeError` if a runtime identifier cannot be resolved.
  """
  @spec get_media_server_config!(binary() | integer(), keyword()) :: MediaServerConfig.t()
  defdelegate get_media_server_config!(id, opts \\ []), to: Mydia.Settings.ServiceConfigs

  @doc """
  Creates a media server configuration.
  """
  @spec create_media_server_config(map()) ::
          {:ok, MediaServerConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_media_server_config(attrs), to: Mydia.Settings.ServiceConfigs

  @doc """
  Updates a media server configuration.
  """
  @spec update_media_server_config(MediaServerConfig.t(), map()) ::
          {:ok, MediaServerConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_media_server_config(config, attrs), to: Mydia.Settings.ServiceConfigs

  @doc """
  Deletes a media server configuration.
  """
  @spec delete_media_server_config(MediaServerConfig.t()) ::
          {:ok, MediaServerConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate delete_media_server_config(config), to: Mydia.Settings.ServiceConfigs

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking media server config changes.
  """
  @spec change_media_server_config(MediaServerConfig.t(), map()) :: Ecto.Changeset.t()
  defdelegate change_media_server_config(config, attrs \\ %{}), to: Mydia.Settings.ServiceConfigs

  # ── Plugin Configs ───────────────────────────────────────────────────

  @doc """
  Lists installed plugin configs from the database and runtime (env/YAML)
  config. Runtime plugins are read-only `runtime::plugin::<slug>` rows.
  """
  @spec list_plugin_configs(keyword()) :: [PluginConfig.t()]
  defdelegate list_plugin_configs(opts \\ []), to: Mydia.Settings.ServiceConfigs

  @doc "Gets a plugin config by ID (DB UUID or `runtime::plugin::<slug>`)."
  @spec get_plugin_config!(binary(), keyword()) :: PluginConfig.t()
  defdelegate get_plugin_config!(id, opts \\ []), to: Mydia.Settings.ServiceConfigs

  @doc "Gets a DB-sourced plugin config by slug, or nil."
  @spec get_plugin_config_by_slug(String.t()) :: PluginConfig.t() | nil
  defdelegate get_plugin_config_by_slug(slug), to: Mydia.Settings.ServiceConfigs

  @doc "Returns the raw DB plugin-config rows (with artifact + manifest, no env merge)."
  @spec get_db_plugin_configs() :: [PluginConfig.t()]
  defdelegate get_db_plugin_configs(), to: Mydia.Settings.ServiceConfigs

  @doc "Creates a plugin config."
  @spec create_plugin_config(map()) :: {:ok, PluginConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_plugin_config(attrs), to: Mydia.Settings.ServiceConfigs

  @doc "Updates a plugin config."
  @spec update_plugin_config(PluginConfig.t(), map()) ::
          {:ok, PluginConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_plugin_config(config, attrs), to: Mydia.Settings.ServiceConfigs

  @doc "Inserts or updates a DB plugin config keyed by slug."
  @spec upsert_plugin_config(map()) :: {:ok, PluginConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate upsert_plugin_config(attrs), to: Mydia.Settings.ServiceConfigs

  @doc "Deletes a plugin config."
  @spec delete_plugin_config(PluginConfig.t()) ::
          {:ok, PluginConfig.t()} | {:error, Ecto.Changeset.t()}
  defdelegate delete_plugin_config(config), to: Mydia.Settings.ServiceConfigs

  @doc "Returns a changeset for tracking plugin config changes."
  @spec change_plugin_config(PluginConfig.t(), map()) :: Ecto.Changeset.t()
  defdelegate change_plugin_config(config, attrs \\ %{}), to: Mydia.Settings.ServiceConfigs

  # ── Library Paths ────────────────────────────────────────────────────

  @doc """
  Lists all library paths.

  Returns library paths from both the database and runtime configuration
  (environment variables). Runtime config paths are returned as structs
  compatible with LibraryPath but without database IDs.
  """
  @spec list_library_paths(keyword()) :: [LibraryPath.t()]
  defdelegate list_library_paths(opts \\ []), to: Mydia.Settings.LibraryPaths

  @doc """
  Derives the TV metadata source implied by the configured `:series`/`:mixed`
  libraries: unanimous source, `:tvdb` when none configured, or `nil` on
  conflict. See `Mydia.Settings.LibraryPaths.derive_tv_metadata_source/0`.
  """
  @spec derive_tv_metadata_source() :: :tvdb | :tmdb | nil
  defdelegate derive_tv_metadata_source(), to: Mydia.Settings.LibraryPaths

  @doc """
  Gets a library path by ID.

  Accepts both database IDs (integers) and runtime identifiers (strings starting
  with "runtime::library_path::"). Runtime identifiers are resolved by looking
  up the path in the runtime configuration.

  Raises `Ecto.NoResultsError` if a database ID is not found, or
  `RuntimeError` if a runtime identifier cannot be resolved.
  """
  @spec get_library_path!(binary() | integer(), keyword()) :: LibraryPath.t()
  defdelegate get_library_path!(id, opts \\ []), to: Mydia.Settings.LibraryPaths

  @doc """
  Creates a library path.
  """
  @spec create_library_path(map()) :: {:ok, LibraryPath.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_library_path(attrs), to: Mydia.Settings.LibraryPaths

  @doc """
  Updates a library path.

  If the path is being changed, validates that files are accessible at the new
  location before allowing the change.
  """
  @spec update_library_path(LibraryPath.t(), map()) ::
          {:ok, LibraryPath.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_library_path(library_path, attrs), to: Mydia.Settings.LibraryPaths

  @doc """
  Validates that files are accessible at a new library path location.

  Samples up to 10 media files from the library path and checks if they are
  accessible at the new location. Returns `:ok` if validation passes, or
  `{:error, message}` with a user-friendly error message if validation fails.

  ## Parameters

    - `library_path` - The existing LibraryPath struct
    - `new_path` - The new path to validate

  ## Examples

      iex> validate_new_library_path(library_path, "/new/media/path")
      :ok

      iex> validate_new_library_path(library_path, "/wrong/path")
      {:error, "Files not accessible at new location. Checked 5 files, 0 found."}
  """
  @spec validate_new_library_path(LibraryPath.t(), String.t()) :: :ok | {:error, String.t()}
  defdelegate validate_new_library_path(library_path, new_path), to: Mydia.Settings.LibraryPaths

  @doc """
  Deletes a library path.
  """
  @spec delete_library_path(LibraryPath.t()) ::
          {:ok, LibraryPath.t()} | {:error, Ecto.Changeset.t()}
  defdelegate delete_library_path(library_path), to: Mydia.Settings.LibraryPaths

  # ── Runtime Configuration ────────────────────────────────────────────

  @doc """
  Lists all configuration settings from the database.

  Note: This function is intentionally database-only (no runtime config merge)
  as it's used by the config loader to build the configuration hierarchy.
  """
  @spec list_config_settings(keyword()) :: [ConfigSetting.t()]
  defdelegate list_config_settings(opts \\ []), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets a configuration setting from the database by key.
  """
  @spec get_config_setting_by_key(String.t()) :: ConfigSetting.t() | nil
  defdelegate get_config_setting_by_key(key), to: Mydia.Settings.RuntimeConfig

  @doc """
  Creates a configuration setting in the database.
  """
  @spec create_config_setting(map()) :: {:ok, ConfigSetting.t()} | {:error, Ecto.Changeset.t()}
  defdelegate create_config_setting(attrs), to: Mydia.Settings.RuntimeConfig

  @doc """
  Updates a configuration setting in the database.
  """
  @spec update_config_setting(ConfigSetting.t(), map()) ::
          {:ok, ConfigSetting.t()} | {:error, Ecto.Changeset.t()}
  defdelegate update_config_setting(config_setting, attrs), to: Mydia.Settings.RuntimeConfig

  @doc """
  Deletes a configuration setting from the database.
  """
  @spec delete_config_setting(ConfigSetting.t()) ::
          {:ok, ConfigSetting.t()} | {:error, Ecto.Changeset.t()}
  defdelegate delete_config_setting(config_setting), to: Mydia.Settings.RuntimeConfig

  @doc """
  Resolves the source (`:env` / `:database` / `:default`) of a config key for UI
  display. Pass the prefetched `all_db_settings` map to avoid per-key N+1 lookups.
  """
  @spec config_source(String.t() | nil, String.t(), %{optional(String.t()) => ConfigSetting.t()}) ::
          :env | :database | :default
  defdelegate config_source(env_var_name, key, all_db_settings), to: Mydia.Settings.RuntimeConfig

  @doc """
  Creates or updates a `ConfigSetting` by key from an attrs map (or struct)
  carrying `:key`, `:value`, `:category`, and optionally `:updated_by_id`.
  """
  @spec upsert_config_setting(map() | struct()) ::
          {:ok, ConfigSetting.t()} | {:error, Ecto.Changeset.t()}
  defdelegate upsert_config_setting(attrs), to: Mydia.Settings.RuntimeConfig

  @doc """
  Parses a stored or submitted config-setting value into a boolean, accepting the
  lenient truthy tokens (`"true"`, `"1"`, `"yes"`, `"on"`) that DB rows and form
  params may carry. The canonical parser for config-setting booleans.
  """
  @spec parse_setting_boolean(term()) :: boolean()
  defdelegate parse_setting_boolean(value), to: Mydia.Settings.RuntimeConfig

  @doc """
  Loads database configuration settings and converts them to a nested map structure.

  Converts flat ConfigSetting records (e.g., key: "server.port", value: "8080")
  into a nested map structure (e.g., %{server: %{port: 8080}}).

  Returns `{:ok, config_map}` where config_map is a nested map, or
  `{:ok, %{}}` if the database is unavailable.
  """
  @spec load_database_config() :: {:ok, map()}
  defdelegate load_database_config(), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets the runtime configuration.

  Returns the full configuration struct loaded at application startup.
  """
  @spec get_runtime_config() :: Mydia.Config.Schema.t()
  defdelegate get_runtime_config(), to: Mydia.Settings.RuntimeConfig

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
  @spec get_config([atom()]) :: term()
  defdelegate get_config(path), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets a configuration value by path with a default.

  ## Examples

      iex> get_config([:server, :port], 8080)
      4000

      iex> get_config([:nonexistent, :key], "default")
      "default"
  """
  @spec get_config([atom()], term()) :: term()
  defdelegate get_config(path, default), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets server configuration.
  """
  @spec get_server_config() :: Mydia.Config.Schema.Server.t() | nil
  defdelegate get_server_config(), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets database configuration.
  """
  @spec get_database_config() :: Mydia.Config.Schema.Database.t() | nil
  defdelegate get_database_config(), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets authentication configuration.
  """
  @spec get_auth_config() :: Mydia.Config.Schema.Auth.t() | nil
  defdelegate get_auth_config(), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets media configuration.
  """
  @spec get_media_config() :: Mydia.Config.Schema.Media.t() | nil
  defdelegate get_media_config(), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets metadata provider configuration.
  """
  @spec get_metadata_config() :: Mydia.Config.Schema.Metadata.t()
  defdelegate get_metadata_config(), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets downloads configuration.
  """
  @spec get_downloads_config() :: Mydia.Config.Schema.Downloads.t() | nil
  defdelegate get_downloads_config(), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets logging configuration.
  """
  @spec get_logging_config() :: Mydia.Config.Schema.Logging.t() | nil
  defdelegate get_logging_config(), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets Oban configuration.
  """
  @spec get_oban_config() :: Mydia.Config.Schema.Oban.t() | nil
  defdelegate get_oban_config(), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets download clients from the runtime configuration.

  Converts runtime config download client maps to DownloadClientConfig structs
  for compatibility with the rest of the application. These structs have stable
  runtime identifiers instead of database IDs (format: "runtime::download_client::name").
  """
  @spec get_runtime_download_clients() :: [DownloadClientConfig.t()]
  defdelegate get_runtime_download_clients(), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets indexers from the runtime configuration.

  Converts runtime config indexer maps to IndexerConfig structs
  for compatibility with the rest of the application. These structs have stable
  runtime identifiers instead of database IDs (format: "runtime::indexer::name").
  """
  @spec get_runtime_indexers() :: [IndexerConfig.t()]
  defdelegate get_runtime_indexers(), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets media servers from the runtime configuration.

  Converts runtime config media server maps to MediaServerConfig structs
  for compatibility with the rest of the application. These structs have stable
  runtime identifiers instead of database IDs (format: "runtime::media_server::name").
  """
  @spec get_runtime_media_servers() :: [MediaServerConfig.t()]
  defdelegate get_runtime_media_servers(), to: Mydia.Settings.RuntimeConfig

  @doc """
  Gets library paths from the runtime configuration.

  Converts runtime config library paths to LibraryPath structs for compatibility
  with the rest of the application. These structs have stable runtime identifiers
  instead of database IDs (format: "runtime::library_path::/path/to/media").

  """
  @spec get_runtime_library_paths() :: [LibraryPath.t()]
  defdelegate get_runtime_library_paths(), to: Mydia.Settings.RuntimeConfig

  @doc """
  Checks if a configuration struct is from runtime config (environment variables)
  rather than the database.

  Runtime configs have IDs that start with "runtime::" and cannot be updated
  via the normal update functions as they are not loaded from the database.

  ## Examples

      iex> runtime_config?(client)
      true

      iex> database_config?(client)
      false
  """
  @spec runtime_config?(map()) :: boolean()
  defdelegate runtime_config?(config), to: Mydia.Settings.RuntimeConfig
end
