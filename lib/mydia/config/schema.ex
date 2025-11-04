defmodule Mydia.Config.Schema do
  @moduledoc """
  Configuration schema with embedded schemas for type safety and validation.
  Defines defaults for all application settings.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
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
      field :movies_path, :string, default: "/media/movies"
      field :tv_path, :string, default: "/media/tv"
      field :scan_interval_hours, :integer, default: 1
    end

    embeds_one :downloads, Downloads, on_replace: :update, primary_key: false do
      field :monitor_interval_minutes, :integer, default: 2
    end

    embeds_one :logging, Logging, on_replace: :update, primary_key: false do
      field :level, :string, default: "info"
      field :format, :string, default: "[$level] $message\n"
    end

    embeds_one :oban, Oban, on_replace: :update, primary_key: false do
      field :poll_interval, :integer, default: 1000
      field :max_age_days, :integer, default: 7
    end

    embeds_many :download_clients, DownloadClient, on_replace: :delete, primary_key: false do
      field :name, :string
      field :type, Ecto.Enum, values: [:qbittorrent, :transmission, :http]
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
    |> cast_embed(:downloads, with: &downloads_changeset/2)
    |> cast_embed(:logging, with: &logging_changeset/2)
    |> cast_embed(:oban, with: &oban_changeset/2)
    |> cast_embed(:download_clients, with: &download_client_changeset/2)
    |> cast_embed(:indexers, with: &indexer_changeset/2)
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
    |> cast(attrs, [:movies_path, :tv_path, :scan_interval_hours])
    |> validate_required([:movies_path, :tv_path])
    |> validate_number(:scan_interval_hours, greater_than: 0)
  end

  defp downloads_changeset(schema, attrs) do
    schema
    |> cast(attrs, [:monitor_interval_minutes])
    |> validate_number(:monitor_interval_minutes, greater_than: 0)
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
    |> validate_inclusion(:type, [:qbittorrent, :transmission, :http])
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
      downloads: %__MODULE__.Downloads{},
      logging: %__MODULE__.Logging{},
      oban: %__MODULE__.Oban{},
      download_clients: [],
      indexers: []
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
