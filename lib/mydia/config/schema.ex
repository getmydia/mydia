defmodule Mydia.Config.Schema do
  @moduledoc """
  Configuration schema with embedded schemas for type safety and validation.
  Defines defaults for all application settings.
  """

  use Ecto.Schema
  import Ecto.Changeset

  require Logger

  alias Mydia.Settings.PathMappingConfig

  @primary_key false

  # Lower bound for an automatic library scan interval, in seconds. Mirrors the
  # floor enforced by Mydia.Settings.LibraryPath, which is the database-layer
  # guarantee. Configured values below it are clamped rather than rejected: see
  # clamp_scan_interval/1.
  @min_scan_interval 900

  @type t :: %__MODULE__{
          server: __MODULE__.Server.t() | nil,
          database: __MODULE__.Database.t() | nil,
          auth: __MODULE__.Auth.t() | nil,
          media: __MODULE__.Media.t() | nil,
          metadata: __MODULE__.Metadata.t() | nil,
          downloads: __MODULE__.Downloads.t() | nil,
          upgrades: __MODULE__.Upgrades.t() | nil,
          logging: __MODULE__.Logging.t() | nil,
          oban: __MODULE__.Oban.t() | nil,
          plugins: __MODULE__.Plugins.t() | nil,
          flaresolverr: __MODULE__.FlareSolverr.t() | nil,
          download_clients: [__MODULE__.DownloadClient.t()],
          indexers: [__MODULE__.Indexer.t()],
          media_servers: [__MODULE__.MediaServer.t()],
          library_paths: [__MODULE__.LibraryPath.t()],
          plugin_installs: [__MODULE__.PluginInstall.t()],
          path_mappings: [__MODULE__.PathMapping.t()]
        }

  embedded_schema do
    embeds_one :server, Server, on_replace: :update, primary_key: false do
      field :port, :integer, default: 4000
      field :host, :string, default: "0.0.0.0"
      field :url_scheme, :string, default: "http"
      field :url_host, :string, default: "localhost"
      field :secret_key_base, :string
      field :guardian_secret_key, :string
    end

    embeds_one :database, Database, on_replace: :update, primary_key: false do
      field :path, :string, default: "mydia_dev.db"
      field :pool_size, :integer, default: 5
      field :timeout, :integer, default: 5000
      field :cache_size, :integer, default: -64_000
      field :busy_timeout, :integer, default: 5000
      field :journal_mode, :string, default: "wal"
      field :synchronous, :string, default: "normal"
    end

    embeds_one :auth, Auth, on_replace: :update, primary_key: false do
      field :local_enabled, :boolean, default: true
      field :oidc_enabled, :boolean, default: false
      field :oidc_issuer, :string
      field :oidc_discovery_document_uri, :string
      field :oidc_client_id, :string
      field :oidc_client_secret, :string
      field :oidc_redirect_uri, :string
      field :oidc_scopes, :string, default: "openid profile email"
      field :jwt_ttl_days, :integer, default: 30
      field :jwt_allowed_drift, :integer, default: 2000
    end

    embeds_one :media, Media, on_replace: :update, primary_key: false do
      # Legacy paths - prefer LIBRARY_PATH_* env vars instead
      field :movies_path, :string
      field :tv_path, :string
      field :movies_auto_organize, :boolean, default: false
      field :tv_auto_organize, :boolean, default: false
      field :auto_search_on_add, :boolean, default: true
      field :monitor_by_default, :boolean, default: true
      field :season_refresh_threshold_hours, :integer, default: 24
      field :completed_show_refresh_threshold_hours, :integer, default: 168
    end

    embeds_one :metadata, Metadata, on_replace: :update, primary_key: false do
      # Language sent to TMDB/TVDB through metadata-relay. Accepts ISO 639-1
      # codes ("de") or BCP 47 language tags ("de-DE", "pt-BR").
      field :language, :string, default: "en-US"
    end

    embeds_one :downloads, Downloads, on_replace: :update, primary_key: false do
      field :monitor_interval_minutes, :integer, default: 2
      # Default TTL (in days) applied when a `release_blacklist` row is
      # inserted without an explicit `expires_at`. See `Mydia.Downloads.Blacklists`
      # (#123).
      field :release_blacklist_default_ttl_days, :integer, default: 30
    end

    embeds_one :upgrades, Upgrades, on_replace: :update, primary_key: false do
      # Master switch for Mydia.Jobs.UpgradeSweep, the daily bounded sweep
      # that looks for quality upgrades to already-present library files.
      field :sweep_enabled, :boolean, default: true
      # Caps indexer searches (not items) a single sweep run may cost, since
      # upgrade-eligible items can be the whole library.
      field :sweep_batch_size, :integer, default: 50
    end

    embeds_one :logging, Logging, on_replace: :update, primary_key: false do
      field :level, :string, default: "info"
      field :format, :string, default: "[$level] $message\n"
    end

    embeds_one :oban, Oban, on_replace: :update, primary_key: false do
      field :poll_interval, :integer, default: 1000
      field :max_age_days, :integer, default: 7
    end

    embeds_one :plugins, Plugins, on_replace: :update, primary_key: false do
      # WASM plugin runtime sandbox limits (KTD4). Fuel metering defaults OFF
      # for raw speed; the event-dispatch path forces it ON regardless (the
      # safety floor against a hung guest draining the pool).
      field :fuel_enabled, :boolean, default: false
      field :fuel_limit, :integer, default: 10_000_000_000
      field :memory_limit_bytes, :integer, default: 67_108_864
      field :invocation_timeout_ms, :integer, default: 5000
      # on-schedule gets its own (larger) budget than on-event: a sync chunks and
      # checkpoints across this window, with wall-clock kill as the only guard
      # (no fuel metering on component stores).
      field :schedule_timeout_ms, :integer, default: 60_000
      field :pool_size, :integer, default: 4
      # Official plugin index (R13). HTTPS is the v1 trust anchor (KTD10), so all
      # index/source URLs are validated to be https at config time.
      field :index_url, :string, default: "https://plugins.getmydia.com/index.json"
      field :extra_source_urls, {:array, :string}, default: []
      # Filesystem override directory (PLUGINS_OVERRIDE_DIR). When set, a
      # `<slug>.wasm` dropped here takes precedence over the DB blob and the
      # image-bundled artifact at activation (layered artifact resolution).
      # Overrides the bytes of a known/bundled slug; capability approval still
      # gates what the plugin may do.
      field :override_dir, :string
    end

    embeds_one :flaresolverr, FlareSolverr, on_replace: :update, primary_key: false do
      field :enabled, :boolean, default: false
      field :url, :string
      field :timeout, :integer, default: 60_000
      field :max_timeout, :integer, default: 120_000
    end

    embeds_many :download_clients, DownloadClient, on_replace: :delete, primary_key: false do
      field :name, :string

      field :type, Ecto.Enum,
        values: [
          :qbittorrent,
          :transmission,
          :rqbit,
          :rtorrent,
          :sabnzbd,
          :nzbget,
          :blackhole,
          :debrid
        ]

      field :enabled, :boolean, default: true
      field :priority, :integer, default: 1
      field :host, :string
      field :port, :integer
      field :use_ssl, :boolean, default: false
      field :url_base, :string
      field :username, :string
      field :password, :string
      field :api_key, :string
      field :category, :string
      field :download_directory, :string
      field :connection_settings, :map, default: %{}
    end

    embeds_many :indexers, Indexer, on_replace: :delete, primary_key: false do
      field :name, :string
      field :type, Ecto.Enum, values: [:prowlarr, :jackett, :public]
      field :enabled, :boolean, default: true
      field :priority, :integer, default: 1
      field :base_url, :string
      field :api_key, :string
      field :indexer_ids, {:array, :string}
      field :categories, {:array, :string}
      field :rate_limit, :integer
      field :timeout, :integer, default: 30000
    end

    embeds_many :media_servers, MediaServer, on_replace: :delete, primary_key: false do
      field :name, :string
      field :type, Ecto.Enum, values: [:plex, :jellyfin]
      field :enabled, :boolean, default: true
      field :url, :string
      field :token, :string
    end

    embeds_many :library_paths, LibraryPath, on_replace: :delete, primary_key: false do
      field :path, :string
      field :type, Ecto.Enum, values: [:movies, :series, :mixed, :music, :books, :adult]
      field :monitored, :boolean, default: true
      field :scan_interval, :integer
    end

    # Env/YAML-sourced installed plugins (PLUGIN_<N>_*). DB-sourced installs
    # live in the `plugin_configs` table; these merge in read-only with a
    # source badge (see Mydia.Settings.RuntimeConfig.get_runtime_plugins/0).
    embeds_many :plugin_installs, PluginInstall, on_replace: :delete, primary_key: false do
      field :slug, :string
      field :name, :string
      field :version, :string
      field :enabled, :boolean, default: true
      field :priority, :integer, default: 1
      field :source_url, :string
      field :integrity_hash, :string
      field :settings, :map, default: %{}
      field :granted_capabilities, :map, default: %{}
    end

    embeds_many :path_mappings, PathMapping, on_replace: :delete, primary_key: false do
      field :remote_prefix, :string
      field :local_prefix, :string
    end
  end

  @doc """
  Builds a changeset for the configuration schema.
  Validates types and required fields.
  """
  def changeset(config \\ %__MODULE__{}, attrs) do
    config
    |> cast(attrs, [])
    |> cast_embed(:server, with: &server_changeset/2)
    |> cast_embed(:database, with: &database_changeset/2)
    |> cast_embed(:auth, with: &auth_changeset/2)
    |> cast_embed(:media, with: &media_changeset/2)
    |> cast_embed(:metadata, with: &metadata_changeset/2)
    |> cast_embed(:downloads, with: &downloads_changeset/2)
    |> cast_embed(:upgrades, with: &upgrades_changeset/2)
    |> cast_embed(:logging, with: &logging_changeset/2)
    |> cast_embed(:oban, with: &oban_changeset/2)
    |> cast_embed(:plugins, with: &plugins_changeset/2)
    |> cast_embed(:flaresolverr, with: &flaresolverr_changeset/2)
    |> cast_embed(:download_clients, with: &download_client_changeset/2)
    |> cast_embed(:indexers, with: &indexer_changeset/2)
    |> cast_embed(:media_servers, with: &media_server_changeset/2)
    |> cast_embed(:library_paths, with: &library_path_changeset/2)
    |> cast_embed(:plugin_installs, with: &plugin_install_changeset/2)
    |> cast_embed(:path_mappings, with: &path_mapping_changeset/2)
    |> validate_configuration()
  end

  defp server_changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :port,
      :host,
      :url_scheme,
      :url_host,
      :secret_key_base,
      :guardian_secret_key
    ])
    |> validate_required([:port, :host, :url_scheme, :url_host])
    |> validate_number(:port, greater_than: 0, less_than: 65536)
    |> validate_inclusion(:url_scheme, ["http", "https"])
  end

  defp database_changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :path,
      :pool_size,
      :timeout,
      :cache_size,
      :busy_timeout,
      :journal_mode,
      :synchronous
    ])
    |> validate_required([:path, :pool_size])
    |> validate_number(:pool_size, greater_than: 0)
    |> validate_number(:timeout, greater_than: 0)
    |> validate_number(:busy_timeout, greater_than: 0)
    |> validate_inclusion(:journal_mode, ["delete", "truncate", "persist", "memory", "wal"])
    |> validate_inclusion(:synchronous, ["off", "normal", "full", "extra"])
  end

  defp auth_changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :local_enabled,
      :oidc_enabled,
      :oidc_issuer,
      :oidc_discovery_document_uri,
      :oidc_client_id,
      :oidc_client_secret,
      :oidc_redirect_uri,
      :oidc_scopes,
      :jwt_ttl_days,
      :jwt_allowed_drift
    ])
    |> validate_required([:local_enabled, :oidc_enabled])
    |> validate_oidc_config()
    |> validate_number(:jwt_ttl_days, greater_than: 0)
    |> validate_number(:jwt_allowed_drift, greater_than_or_equal_to: 0)
  end

  defp media_changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :movies_path,
      :tv_path,
      :movies_auto_organize,
      :tv_auto_organize,
      :auto_search_on_add,
      :monitor_by_default,
      :season_refresh_threshold_hours,
      :completed_show_refresh_threshold_hours
    ])
    # movies_path and tv_path are optional legacy fields
    |> validate_number(:season_refresh_threshold_hours, greater_than: 0)
    |> validate_number(:completed_show_refresh_threshold_hours, greater_than: 0)
  end

  defp metadata_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:language])
    |> validate_required([:language])
    |> validate_length(:language, min: 2, max: 16)
  end

  defp downloads_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:monitor_interval_minutes, :release_blacklist_default_ttl_days])
    |> validate_number(:monitor_interval_minutes, greater_than: 0)
    |> validate_number(:release_blacklist_default_ttl_days, greater_than: 0)
  end

  defp upgrades_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:sweep_enabled, :sweep_batch_size])
    |> validate_required([:sweep_enabled, :sweep_batch_size])
    |> validate_number(:sweep_batch_size, greater_than: 0)
  end

  defp logging_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:level, :format])
    |> validate_required([:level])
    |> validate_inclusion(:level, ["debug", "info", "warning", "error"])
  end

  defp oban_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:poll_interval, :max_age_days])
    |> validate_number(:poll_interval, greater_than: 0)
    |> validate_number(:max_age_days, greater_than: 0)
  end

  defp plugins_changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :fuel_enabled,
      :fuel_limit,
      :memory_limit_bytes,
      :invocation_timeout_ms,
      :schedule_timeout_ms,
      :pool_size,
      :index_url,
      :extra_source_urls,
      :override_dir
    ])
    |> validate_required([:fuel_enabled])
    |> validate_number(:fuel_limit, greater_than: 0)
    |> validate_number(:memory_limit_bytes, greater_than: 0)
    |> validate_number(:invocation_timeout_ms, greater_than: 0)
    |> validate_number(:schedule_timeout_ms, greater_than: 0)
    |> validate_number(:pool_size, greater_than: 0)
    |> validate_https_source(:index_url)
    |> validate_https_sources(:extra_source_urls)
  end

  # KTD10: the index/source transport is the v1 trust anchor, so a non-HTTPS
  # source URL is rejected at config-validation time (no downgrade).
  defp validate_https_source(changeset, field) do
    case get_field(changeset, field) do
      nil ->
        changeset

      "" ->
        changeset

      url ->
        if https?(url), do: changeset, else: add_error(changeset, field, "must be an https URL")
    end
  end

  defp validate_https_sources(changeset, field) do
    urls = get_field(changeset, field) || []

    if Enum.all?(urls, &https?/1) do
      changeset
    else
      add_error(changeset, field, "all plugin source URLs must be https")
    end
  end

  defp https?(url) when is_binary(url), do: URI.parse(url).scheme == "https"
  defp https?(_), do: false

  defp flaresolverr_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :url, :timeout, :max_timeout])
    |> validate_flaresolverr_url()
    |> validate_number(:timeout, greater_than: 0)
    |> validate_number(:max_timeout, greater_than: 0)
  end

  defp validate_flaresolverr_url(changeset) do
    enabled = get_field(changeset, :enabled)
    url = get_field(changeset, :url)

    if enabled && (is_nil(url) || url == "") do
      add_error(changeset, :url, "is required when FlareSolverr is enabled")
    else
      changeset
    end
  end

  defp download_client_changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :name,
      :type,
      :enabled,
      :priority,
      :host,
      :port,
      :use_ssl,
      :url_base,
      :username,
      :password,
      :api_key,
      :category,
      :download_directory,
      :connection_settings
    ])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, [
      :qbittorrent,
      :transmission,
      :rqbit,
      :rtorrent,
      :http,
      :sabnzbd,
      :nzbget,
      :blackhole,
      :debrid
    ])
    |> validate_download_client_by_type()
    |> validate_number(:port, greater_than: 0, less_than: 65536)
    |> validate_number(:priority, greater_than: 0)
  end

  # Network clients need host/port; hostless ones (blackhole, debrid) don't.
  # Debrid additionally needs an api_key and a recognised provider.
  defp validate_download_client_by_type(changeset) do
    case get_field(changeset, :type) do
      :debrid ->
        changeset
        |> validate_required([:api_key])
        |> validate_debrid_provider()

      :blackhole ->
        changeset

      _network_client ->
        validate_required(changeset, [:host, :port])
    end
  end

  defp validate_debrid_provider(changeset) do
    providers = Mydia.Settings.DownloadClientConfig.debrid_providers()
    provider = get_field(changeset, :connection_settings)["provider"]

    if provider in providers do
      changeset
    else
      add_error(
        changeset,
        :connection_settings,
        "must include provider (one of: #{Enum.join(providers, ", ")})"
      )
    end
  end

  defp indexer_changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :name,
      :type,
      :enabled,
      :priority,
      :base_url,
      :api_key,
      :indexer_ids,
      :categories,
      :rate_limit,
      :timeout
    ])
    |> validate_required([:name, :type, :base_url])
    |> validate_inclusion(:type, [:prowlarr, :jackett, :public])
    |> validate_number(:priority, greater_than: 0)
    |> validate_number(:rate_limit, greater_than: 0)
    |> validate_number(:timeout, greater_than: 0)
  end

  defp media_server_changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :name,
      :type,
      :enabled,
      :url,
      :token
    ])
    |> validate_required([:name, :type, :url])
    |> validate_inclusion(:type, [:plex, :jellyfin])
  end

  defp library_path_changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :path,
      :type,
      :monitored,
      :scan_interval
    ])
    |> validate_required([:path, :type])
    |> validate_inclusion(:type, [:movies, :series, :mixed, :music, :books, :adult])
    |> clamp_scan_interval()
  end

  # Config is loaded by Mydia.Application before the supervision tree starts, and
  # Config.Loader.load!/1 raises on an invalid changeset, so rejecting a too-small
  # scan_interval would put an upgrading instance into a boot crash loop over a
  # value that did nothing in any released version. Clamp and say so instead.
  # Applies to every config source (env, YAML, database) because they all merge
  # into this changeset.
  defp clamp_scan_interval(changeset) do
    case get_change(changeset, :scan_interval) do
      interval when is_integer(interval) and interval < @min_scan_interval ->
        Logger.warning(
          "Library path scan_interval of #{interval}s is below the #{@min_scan_interval}s minimum; using #{@min_scan_interval}s"
        )

        put_change(changeset, :scan_interval, @min_scan_interval)

      _ ->
        changeset
    end
  end

  defp plugin_install_changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :slug,
      :name,
      :version,
      :enabled,
      :priority,
      :source_url,
      :integrity_hash,
      :settings,
      :granted_capabilities
    ])
    |> validate_required([:slug, :name])
    |> validate_number(:priority, greater_than: 0)
  end

  defp path_mapping_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:remote_prefix, :local_prefix])
    |> update_change(:remote_prefix, &PathMappingConfig.normalize_prefix/1)
    |> update_change(:local_prefix, &PathMappingConfig.normalize_prefix/1)
    |> validate_required([:remote_prefix, :local_prefix])
    |> validate_path_mapping_absolute(:remote_prefix)
    |> validate_path_mapping_absolute(:local_prefix)
    |> validate_path_mapping_no_traversal(:remote_prefix)
    |> validate_path_mapping_no_traversal(:local_prefix)
    |> validate_path_mapping_remote_prefix_specific()
    |> validate_path_mapping_distinct_prefixes()
  end

  defp validate_path_mapping_absolute(changeset, field) do
    case get_field(changeset, field) do
      "/" <> _ -> changeset
      nil -> changeset
      _ -> add_error(changeset, field, "must be an absolute path (start with /)")
    end
  end

  defp validate_path_mapping_no_traversal(changeset, field) do
    case get_field(changeset, field) do
      value when is_binary(value) ->
        if ".." in Path.split(value) do
          add_error(changeset, field, "must not contain '..' segments")
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_path_mapping_remote_prefix_specific(changeset) do
    case get_field(changeset, :remote_prefix) do
      value when is_binary(value) ->
        if length(Path.split(value)) < 3 do
          add_error(
            changeset,
            :remote_prefix,
            "must be at least two path segments deep (e.g. /downloads/complete)"
          )
        else
          changeset
        end

      _ ->
        changeset
    end
  end

  defp validate_path_mapping_distinct_prefixes(changeset) do
    remote = get_field(changeset, :remote_prefix)
    local = get_field(changeset, :local_prefix)

    if not is_nil(remote) and remote == local do
      add_error(changeset, :local_prefix, "must differ from the remote prefix")
    else
      changeset
    end
  end

  defp validate_oidc_config(changeset) do
    oidc_enabled = get_field(changeset, :oidc_enabled)

    if oidc_enabled do
      changeset
      |> validate_required([
        :oidc_client_id,
        :oidc_client_secret
      ])
      |> validate_oidc_issuer()
    else
      changeset
    end
  end

  defp validate_oidc_issuer(changeset) do
    issuer = get_field(changeset, :oidc_issuer)
    discovery = get_field(changeset, :oidc_discovery_document_uri)

    if is_nil(issuer) and is_nil(discovery) do
      add_error(
        changeset,
        :oidc_issuer,
        "either oidc_issuer or oidc_discovery_document_uri must be provided when OIDC is enabled"
      )
    else
      changeset
    end
  end

  defp validate_configuration(changeset) do
    # At least one auth method must be enabled
    if changeset.valid? do
      auth = get_embed(changeset, :auth)

      if auth do
        local_enabled = Ecto.Changeset.get_field(auth, :local_enabled, false)
        oidc_enabled = Ecto.Changeset.get_field(auth, :oidc_enabled, false)

        if not local_enabled and not oidc_enabled do
          add_error(
            changeset,
            :auth,
            "at least one authentication method (local or OIDC) must be enabled"
          )
        else
          changeset
        end
      else
        changeset
      end
    else
      changeset
    end
  end

  @doc """
  Returns the default configuration as a map.
  """
  def defaults do
    # Initialize with all embedded schemas set to their defaults
    base_config = %__MODULE__{
      server: %__MODULE__.Server{},
      database: %__MODULE__.Database{},
      auth: %__MODULE__.Auth{},
      media: %__MODULE__.Media{},
      metadata: %__MODULE__.Metadata{},
      downloads: %__MODULE__.Downloads{},
      upgrades: %__MODULE__.Upgrades{},
      logging: %__MODULE__.Logging{},
      oban: %__MODULE__.Oban{},
      plugins: %__MODULE__.Plugins{},
      flaresolverr: %__MODULE__.FlareSolverr{},
      download_clients: [],
      indexers: [],
      media_servers: [],
      library_paths: [],
      plugin_installs: [],
      path_mappings: []
    }

    # Run through changeset to apply defaults from field definitions
    changeset = changeset(base_config, %{})

    if changeset.valid? do
      Ecto.Changeset.apply_changes(changeset)
    else
      base_config
    end
  end
end
