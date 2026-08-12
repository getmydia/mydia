defmodule Mydia.Settings.SubtitleProviderConfig do
  @moduledoc """
  Instance-scoped subtitle provider configuration.

  Shaped after `Mydia.Settings.IndexerConfig` so subtitle providers layer over
  YAML and env the same way every other service does. Configuration belongs to
  the install, not to a user: a self-hosted household shares one set of
  providers, and per-user rows would mean one member's exhausted quota is
  invisible to everyone else.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @provider_types [:relay, :opensubtitles, :gestdown, :subdl]

  @type t :: %__MODULE__{
          id: binary(),
          name: String.t() | nil,
          type: atom() | nil,
          enabled: boolean(),
          priority: integer(),
          username: String.t() | nil,
          password: String.t() | nil,
          api_key: String.t() | nil,
          env_name: String.t() | nil,
          connection_settings: map() | nil,
          quota_remaining: integer() | nil,
          quota_total: integer() | nil,
          quota_reset_at: DateTime.t() | nil,
          vip_status: boolean(),
          updated_by_id: binary() | nil
        }

  schema "subtitle_provider_configs" do
    field :name, :string
    field :type, Ecto.Enum, values: @provider_types
    field :enabled, :boolean, default: true
    field :priority, :integer, default: 0
    field :username, :string
    field :password, :string
    field :api_key, :string
    field :env_name, :string
    field :connection_settings, Mydia.Settings.JsonMapType

    field :quota_remaining, :integer
    field :quota_total, :integer
    field :quota_reset_at, :utc_datetime
    field :vip_status, :boolean, default: false

    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the provider types this schema accepts.
  """
  def provider_types, do: @provider_types

  def changeset(config, attrs) do
    config
    |> cast(attrs, [
      :name,
      :type,
      :enabled,
      :priority,
      :username,
      :password,
      :api_key,
      :env_name,
      :connection_settings,
      :quota_remaining,
      :quota_total,
      :quota_reset_at,
      :vip_status,
      :updated_by_id
    ])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, @provider_types)
    |> validate_number(:priority, greater_than_or_equal_to: 0)
    |> unique_constraint(:name)
    |> validate_credentials()
  end

  @doc """
  Quota update changeset, used after a download reports remaining quota.
  """
  def quota_changeset(config, attrs) do
    config
    |> cast(attrs, [:quota_remaining, :quota_total, :quota_reset_at, :vip_status])
    |> validate_number(:quota_remaining, greater_than_or_equal_to: 0)
    |> validate_number(:quota_total, greater_than: 0)
  end

  defp validate_credentials(changeset) do
    case get_field(changeset, :type) do
      :opensubtitles -> require_open_subtitles_credentials(changeset)
      :subdl -> require_present(changeset, :api_key, "SubDL requires an API key")
      _ -> changeset
    end
  end

  defp require_open_subtitles_credentials(changeset) do
    username = get_field(changeset, :username)
    password = get_field(changeset, :password)
    api_key = get_field(changeset, :api_key)

    if present?(api_key) and present?(username) and present?(password) do
      changeset
    else
      add_error(
        changeset,
        :username,
        "OpenSubtitles requires an API key, a username and a password"
      )
    end
  end

  defp require_present(changeset, field, message) do
    if present?(get_field(changeset, field)) do
      changeset
    else
      add_error(changeset, field, message)
    end
  end

  defp present?(value), do: is_binary(value) and value != ""
end
