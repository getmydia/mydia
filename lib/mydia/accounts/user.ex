defmodule Mydia.Accounts.User do
  @moduledoc """
  Schema for users with support for both OIDC and local authentication.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @role_values ~w(admin user readonly guest)

  @type t :: %__MODULE__{
          id: binary(),
          username: String.t() | nil,
          email: String.t() | nil,
          password_hash: String.t() | nil,
          password: String.t() | nil,
          password_confirmation: String.t() | nil,
          oidc_sub: String.t() | nil,
          oidc_issuer: String.t() | nil,
          role: String.t(),
          display_name: String.t() | nil,
          avatar_url: String.t() | nil,
          last_login_at: DateTime.t() | nil,
          preference: Mydia.Accounts.UserPreference.t() | nil | Ecto.Association.NotLoaded.t(),
          access_restriction:
            Mydia.Accounts.AccessRestriction.t() | nil | Ecto.Association.NotLoaded.t(),
          api_keys: [Mydia.Accounts.ApiKey.t()] | Ecto.Association.NotLoaded.t(),
          media_requests: [Mydia.Media.MediaRequest.t()] | Ecto.Association.NotLoaded.t(),
          approved_requests: [Mydia.Media.MediaRequest.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "users" do
    field :username, :string
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true
    field :password_confirmation, :string, virtual: true
    field :oidc_sub, :string
    field :oidc_issuer, :string
    field :role, :string, default: "guest"
    field :display_name, :string
    field :avatar_url, :string
    field :last_login_at, :utc_datetime

    has_one :preference, Mydia.Accounts.UserPreference
    has_one :access_restriction, Mydia.Accounts.AccessRestriction
    has_many :api_keys, Mydia.Accounts.ApiKey
    has_many :media_requests, Mydia.Media.MediaRequest, foreign_key: :requester_id
    has_many :approved_requests, Mydia.Media.MediaRequest, foreign_key: :approved_by_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a user with local authentication.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [
      :username,
      :email,
      :password,
      :password_confirmation,
      :role,
      :display_name,
      :avatar_url
    ])
    |> validate_required([:username, :email, :role])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:username, min: 3, max: 50)
    |> validate_inclusion(:role, @role_values)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
    |> validate_password()
    |> hash_password()
  end

  @doc """
  Changeset for creating or updating a user via OIDC.
  """
  def oidc_changeset(user, attrs) do
    user
    |> cast(attrs, [:oidc_sub, :oidc_issuer, :email, :display_name, :avatar_url, :role])
    |> validate_required([:oidc_sub, :oidc_issuer, :role])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_inclusion(:role, @role_values)
    |> unique_constraint(:oidc_sub)
    |> unique_constraint(:email)
  end

  @doc """
  Changeset for updating last login timestamp.
  """
  def login_changeset(user) do
    change(user, last_login_at: DateTime.utc_now() |> DateTime.truncate(:second))
  end

  @doc """
  Changeset for updating a user's password.
  """
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [:password, :password_confirmation])
    |> validate_required([:password])
    |> validate_password()
    |> hash_password()
  end

  @doc """
  Changeset for updating only a user's role.

  Used by admins to change a user's role without re-validating other
  fields. This is required for OIDC-created users, which have a `nil`
  username and would otherwise fail the local `changeset/2` validations.
  """
  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_inclusion(:role, @role_values)
  end

  @doc """
  Returns the list of valid role values.
  """
  def valid_roles, do: @role_values

  @doc """
  Changeset for updating a user's profile (display_name and avatar_url only).
  """
  def profile_changeset(user, attrs) do
    user
    |> cast(attrs, [:display_name, :avatar_url])
    |> validate_length(:display_name, max: 100)
    |> validate_format(:avatar_url, ~r/^https?:\/\//, message: "must be a valid URL")
  end

  # Validate password requirements
  defp validate_password(changeset) do
    changeset
    |> validate_length(:password, min: 8, message: "must be at least 8 characters")
    |> validate_confirmation(:password, message: "does not match password")
  end

  # Hash the password if it's present
  defp hash_password(changeset) do
    case get_change(changeset, :password) do
      nil ->
        changeset

      password ->
        changeset
        |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)
    end
  end
end
