defmodule Mydia.Integrations.UserIntegration do
  @moduledoc """
  Schema for external service integrations linked to a user.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          provider: String.t() | nil,
          access_token: String.t() | nil,
          refresh_token: String.t() | nil,
          token_expires_at: DateTime.t() | nil,
          external_user_id: String.t() | nil,
          external_username: String.t() | nil,
          scopes: String.t() | nil,
          enabled: boolean(),
          last_synced_at: DateTime.t() | nil,
          settings: map(),
          user: Mydia.Accounts.User.t() | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "user_integrations" do
    field :provider, :string
    field :access_token, :string
    field :refresh_token, :string
    field :token_expires_at, :utc_datetime
    field :external_user_id, :string
    field :external_username, :string
    field :scopes, :string
    field :enabled, :boolean, default: true
    field :last_synced_at, :utc_datetime
    field :settings, :map, default: %{}

    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating an integration.
  """
  def changeset(integration, attrs) do
    integration
    |> cast(attrs, [
      :provider,
      :access_token,
      :refresh_token,
      :token_expires_at,
      :external_user_id,
      :external_username,
      :scopes,
      :enabled,
      :last_synced_at,
      :settings
    ])
    |> validate_required([:provider, :access_token])
    |> unique_constraint([:user_id, :provider])
  end

  @doc """
  Returns true if the access token has expired.
  """
  def token_expired?(%__MODULE__{token_expires_at: nil}), do: false

  def token_expired?(%__MODULE__{token_expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :gt
  end
end
