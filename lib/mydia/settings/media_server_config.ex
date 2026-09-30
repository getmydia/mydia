defmodule Mydia.Settings.MediaServerConfig do
  @moduledoc """
  Schema for native media server configurations (Jellyfin). Plex is a plugin.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          name: String.t() | nil,
          type: atom() | nil,
          enabled: boolean(),
          url: String.t() | nil,
          token: String.t() | nil,
          connection_settings: map() | nil,
          machine_identifier: String.t() | nil,
          connections: [map()],
          server_access_token: String.t() | nil,
          last_auth_error: String.t() | nil,
          last_auth_error_at: DateTime.t() | nil,
          connections_refreshed_at: DateTime.t() | nil,
          updated_by: Mydia.Accounts.User.t() | nil | Ecto.Association.NotLoaded.t(),
          updated_by_id: binary() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  @server_types [:jellyfin]

  schema "media_server_configs" do
    field :name, :string
    field :type, Ecto.Enum, values: @server_types
    field :enabled, :boolean, default: true
    field :url, :string
    field :token, :string
    field :connection_settings, Mydia.Settings.JsonMapType
    field :machine_identifier, :string
    field :connections, Mydia.Settings.JsonListType, default: []
    field :server_access_token, :string, redact: true
    field :last_auth_error, :string
    field :last_auth_error_at, :utc_datetime
    field :connections_refreshed_at, :utc_datetime

    belongs_to :updated_by, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a media server config.
  """
  def changeset(media_server_config, attrs) do
    media_server_config
    |> cast(attrs, [
      :name,
      :type,
      :enabled,
      :url,
      :token,
      :connection_settings,
      :machine_identifier,
      :connections,
      :server_access_token,
      :last_auth_error,
      :last_auth_error_at,
      :connections_refreshed_at,
      :updated_by_id
    ])
    |> validate_required([:name, :type])
    |> validate_inclusion(:type, @server_types)
    |> validate_addressable()
    |> unique_constraint(:name)
  end

  # `Client.Jellyfin` calls `String.trim_trailing(config.url, "/")` directly,
  # which raises on nil, so a native server always needs a url.
  defp validate_addressable(changeset) do
    if present?(get_field(changeset, :url)),
      do: changeset,
      else: add_error(changeset, :url, "can't be blank")
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""
end
