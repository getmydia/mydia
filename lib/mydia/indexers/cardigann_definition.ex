defmodule Mydia.Indexers.CardigannDefinition do
  @moduledoc """
  Schema for Cardigann indexer definitions fetched from Prowlarr/Cardigann GitHub repository.

  Stores the YAML definition and metadata for each indexer, allowing direct integration
  without external Prowlarr/Jackett instances.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @indexer_types ["public", "private", "semi-private"]
  @health_statuses ["healthy", "degraded", "unhealthy", "unknown"]

  @type t :: %__MODULE__{
          id: binary(),
          indexer_id: String.t() | nil,
          name: String.t() | nil,
          description: String.t() | nil,
          language: String.t() | nil,
          type: String.t() | nil,
          encoding: String.t() | nil,
          links: map() | nil,
          active_link: String.t() | nil,
          link_status: map() | nil,
          capabilities: map() | nil,
          definition: String.t() | nil,
          schema_version: String.t() | nil,
          enabled: boolean(),
          config: map() | nil,
          last_synced_at: DateTime.t() | nil,
          health_status: String.t(),
          last_health_check_at: DateTime.t() | nil,
          last_successful_query_at: DateTime.t() | nil,
          consecutive_failures: integer(),
          flaresolverr_required: boolean(),
          flaresolverr_enabled: boolean(),
          search_sessions:
            [Mydia.Indexers.CardigannSearchSession.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "cardigann_definitions" do
    field :indexer_id, :string
    field :name, :string
    field :description, :string
    field :language, :string
    field :type, :string
    field :encoding, :string
    field :links, Mydia.Settings.JsonMapType
    field :active_link, :string
    field :link_status, Mydia.Settings.JsonMapType
    field :capabilities, Mydia.Settings.JsonMapType
    field :definition, :string
    field :schema_version, :string
    field :enabled, :boolean, default: false
    field :config, Mydia.Settings.JsonMapType
    field :last_synced_at, :utc_datetime

    # Health check fields
    field :health_status, :string, default: "unknown"
    field :last_health_check_at, :utc_datetime
    field :last_successful_query_at, :utc_datetime
    field :consecutive_failures, :integer, default: 0

    # FlareSolverr fields
    field :flaresolverr_required, :boolean, default: false
    field :flaresolverr_enabled, :boolean, default: false

    has_many :search_sessions, Mydia.Indexers.CardigannSearchSession,
      foreign_key: :cardigann_definition_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a Cardigann definition from synced data.
  """
  def changeset(definition, attrs) do
    definition
    |> cast(attrs, [
      :indexer_id,
      :name,
      :description,
      :language,
      :type,
      :encoding,
      :links,
      :active_link,
      :link_status,
      :capabilities,
      :definition,
      :schema_version,
      :enabled,
      :config,
      :last_synced_at,
      :flaresolverr_required,
      :flaresolverr_enabled
    ])
    |> validate_required([
      :indexer_id,
      :name,
      :type,
      :links,
      :capabilities,
      :definition,
      :schema_version
    ])
    |> validate_inclusion(:type, @indexer_types)
    |> unique_constraint(:indexer_id)
  end

  @doc """
  Changeset for enabling/disabling an indexer.
  """
  def toggle_changeset(definition, attrs) do
    definition
    |> cast(attrs, [:enabled])
    |> validate_required([:enabled])
  end

  @doc """
  Changeset for updating user-specific configuration (credentials, settings).
  """
  def config_changeset(definition, attrs) do
    definition
    |> cast(attrs, [:config])
    |> validate_required([:config])
  end

  @doc """
  Changeset for updating health check status and timestamps.
  """
  def health_check_changeset(definition, attrs) do
    definition
    |> cast(attrs, [
      :health_status,
      :last_health_check_at,
      :last_successful_query_at,
      :consecutive_failures
    ])
    |> validate_inclusion(:health_status, @health_statuses)
  end

  @doc """
  Changeset for updating FlareSolverr settings.
  """
  def flaresolverr_changeset(definition, attrs) do
    definition
    |> cast(attrs, [:flaresolverr_required, :flaresolverr_enabled])
  end

  @doc """
  Returns true if this indexer should use FlareSolverr.

  FlareSolverr is used when:
  1. The indexer is marked as requiring FlareSolverr, AND
  2. The user has enabled FlareSolverr for this indexer (or it hasn't been explicitly disabled)
  """
  def use_flaresolverr?(%__MODULE__{flaresolverr_required: true, flaresolverr_enabled: true}),
    do: true

  def use_flaresolverr?(%__MODULE__{flaresolverr_required: true, flaresolverr_enabled: nil}),
    do: true

  def use_flaresolverr?(_), do: false
end
