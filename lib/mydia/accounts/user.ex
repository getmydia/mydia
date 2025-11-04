defmodule Mydia.Accounts.User do
  @moduledoc """
  Schema for users with support for both OIDC and local authentication.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @role_values ~w(admin user readonly)

  schema "users" do
    field :username, :string
    field :email, :string
    field :password_hash, :string
    field :password, :string, virtual: true
    field :oidc_sub, :string
    field :oidc_issuer, :string
    field :role, :string, default: "user"
    field :display_name, :string
    field :avatar_url, :string
    field :last_login_at, :utc_datetime

    has_many :api_keys, Mydia.Accounts.ApiKey

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a user with local authentication.
  """
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :email, :password, :role, :display_name, :avatar_url])
    |> validate_required([:username, :email, :role])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+$/, message: "must be a valid email")
    |> validate_length(:username, min: 3, max: 50)
    |> validate_inclusion(:role, @role_values)
    |> unique_constraint(:username)
    |> unique_constraint(:email)
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
  Returns the list of valid role values.
  """
  def valid_roles, do: @role_values

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
