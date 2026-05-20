defmodule Mydia.Config.Schema do
  @moduledoc """
  Configuration schema with embedded schemas for type safety and validation.
  Defines defaults for all application settings.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  @type t :: %__MODULE__{
          server: __MODULE__.Server.t() | nil,
          database: __MODULE__.Database.t() | nil,
          auth: __MODULE__.Auth.t() | nil,
          media: __MODULE__.Media.t() | nil,
          metadata: __MODULE__.Metadata.t() | nil,
          downloads: __MODULE__.Downloads.t() | nil,
          logging: __MODULE__.Logging.t() | nil,
          oban: __MODULE__.Oban.t() | nil,
          hooks: __MODULE__.Hooks.t() | nil,
          flaresolverr: __MODULE__.FlareSolverr.t() | nil,
          streaming: __MODULE__.Streaming.t() | nil,
          download_clients: [__MODULE__.DownloadClient.t()],
          indexers: [__MODULE__.Indexer.t()],
          media_servers: [__MODULE__.MediaServer.t()],
          library_paths: [__MODULE__.LibraryPath.t()]
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
      field :scan_interval_hours, :integer, default: 1
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

    embeds_one :logging, Logging, on_replace: :update, primary_key: false do
      field :level, :string, default: "info"
      field :format, :string, default: "[$level] $message\n"
    end

    embeds_one :oban, Oban, on_replace: :update, primary_key: false do
      field :poll_interval, :integer, default: 1000
      field :max_age_days, :integer, default: 7
    end

    embeds_one :hooks, Hooks, on_replace: :update, primary_key: false do
      field :enabled, :boolean, default: true
      field :directory, :string, default: "hooks"
      field :default_timeout_ms, :integer, default: 5000
      field :max_timeout_ms, :integer, default: 30000
    end

    embeds_one :flaresolverr, FlareSolverr, on_replace: :update, primary_key: false do
      field :enabled, :boolean, default: false
      field :url, :string
      field :timeout, :integer, default: 60_000
      field :max_timeout, :integer, default: 120_000
    end

    embeds_one :streaming, Streaming, on_replace: :update, primary_key: false do
      field :embedded_enabled, :boolean, default: false
      field :concurrent_cap, :integer, default: 3
      field :torrent_staging_dir, :string, default: "/tmp/mydia/streaming"
    end

    embeds_many :download_clients, DownloadClient, on_replace: :delete, primary_key: false do
      field :name, :string

      field :type, Ecto.Enum,
        values: [:qbittorrent, :transmission, :rtorrent, :http, :sabnzbd, :nzbget]

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
      field :scan_interval, :integer, default: 3600
      field :quality_profile_id, :integer
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
    |> cast_embed(:logging, with: &logging_changeset/2)
    |> cast_embed(:oban, with: &oban_changeset/2)
    |> cast_embed(:hooks, with: &hooks_changeset/2)
    |> cast_embed(:flaresolverr, with: &flaresolverr_changeset/2)
    |> cast_embed(:streaming, with: &streaming_changeset/2)
    |> cast_embed(:download_clients, with: &download_client_changeset/2)
    |> cast_embed(:indexers, with: &indexer_changeset/2)
    |> cast_embed(:media_servers, with: &media_server_changeset/2)
    |> cast_embed(:library_paths, with: &library_path_changeset/2)
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
      :scan_interval_hours,
      :auto_search_on_add,
      :monitor_by_default,
      :season_refresh_threshold_hours,
      :completed_show_refresh_threshold_hours
    ])
    # movies_path and tv_path are optional legacy fields
    |> validate_number(:scan_interval_hours, greater_than: 0)
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

  defp hooks_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :directory, :default_timeout_ms, :max_timeout_ms])
    |> validate_required([:enabled, :directory])
    |> validate_number(:default_timeout_ms, greater_than: 0)
    |> validate_number(:max_timeout_ms, greater_than: 0)
  end

  defp flaresolverr_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :url, :timeout, :max_timeout])
    |> validate_flaresolverr_url()
    |> validate_number(:timeout, greater_than: 0)
    |> validate_number(:max_timeout, greater_than: 0)
  end

  defp streaming_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:embedded_enabled, :concurrent_cap, :torrent_staging_dir])
    |> validate_required([:embedded_enabled])
    |> validate_number(:concurrent_cap, greater_than: 0)
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
      :download_directory
    ])
    |> validate_required([:name, :type, :host, :port])
    |> validate_inclusion(:type, [
      :qbittorrent,
      :transmission,
      :rtorrent,
      :http,
      :sabnzbd,
      :nzbget
    ])
    |> validate_number(:port, greater_than: 0, less_than: 65536)
    |> validate_number(:priority, greater_than: 0)
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
      :scan_interval,
      :quality_profile_id
    ])
    |> validate_required([:path, :type])
    |> validate_inclusion(:type, [:movies, :series, :mixed, :music, :books, :adult])
    |> validate_number(:scan_interval, greater_than: 0)
    |> validate_number(:quality_profile_id, greater_than: 0)
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
      logging: %__MODULE__.Logging{},
      oban: %__MODULE__.Oban{},
      hooks: %__MODULE__.Hooks{},
      flaresolverr: %__MODULE__.FlareSolverr{},
      streaming: %__MODULE__.Streaming{},
      download_clients: [],
      indexers: [],
      media_servers: [],
      library_paths: []
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
