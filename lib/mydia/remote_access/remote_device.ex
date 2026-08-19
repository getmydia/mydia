defmodule Mydia.RemoteAccess.RemoteDevice do
  @moduledoc """
  Schema for paired client devices.
  Represents a mobile or web client that has been authorized to access this instance remotely.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{
          id: binary(),
          device_name: String.t() | nil,
          platform: String.t() | nil,
          token_hash: String.t() | nil,
          token: String.t() | nil,
          last_seen_at: DateTime.t() | nil,
          revoked_at: DateTime.t() | nil,
          user: Mydia.Accounts.User.t() | Ecto.Association.NotLoaded.t(),
          user_id: binary() | nil,
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "remote_devices" do
    field :device_name, :string
    field :platform, :string
    field :token_hash, :string
    field :token, :string, virtual: true
    field :last_seen_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :user, Mydia.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new device pairing.
  """
  def changeset(device, attrs) do
    device
    |> cast(attrs, [
      :device_name,
      :platform,
      :token,
      :user_id
    ])
    |> validate_required([
      :device_name,
      :platform,
      :token,
      :user_id
    ])
    |> validate_length(:device_name, min: 1, max: 100)
    |> validate_length(:platform, min: 1, max: 50)
    |> hash_token()
    |> foreign_key_constraint(:user_id)
    |> unique_constraint(:token_hash)
  end

  @doc """
  Changeset for updating last seen timestamp.
  """
  def seen_changeset(device) do
    # SQLite doesn't support microseconds, so truncate to seconds
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(device, last_seen_at: now)
  end

  @doc """
  Changeset for revoking a device.
  """
  def revoke_changeset(device) do
    # SQLite doesn't support microseconds, so truncate to seconds
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    change(device, revoked_at: now)
  end

  @doc """
  Returns true if the device has been revoked.
  """
  def revoked?(%__MODULE__{revoked_at: nil}), do: false
  def revoked?(%__MODULE__{revoked_at: _}), do: true

  # Hash the device token if it's present
  defp hash_token(changeset) do
    case get_change(changeset, :token) do
      nil ->
        changeset

      token ->
        changeset
        |> put_change(:token_hash, hash_device_token(token))
        |> delete_change(:token)
    end
  end

  # Use Argon2 for hashing device tokens (consistent with API keys)
  defp hash_device_token(token) do
    Argon2.hash_pwd_salt(token)
  end
end
