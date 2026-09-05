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
          username_source: String.t() | nil,
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
          api_keys: [Mydia.Accounts.ApiKey.t()] | Ecto.Association.NotLoaded.t(),
          media_requests: [Mydia.Media.MediaRequest.t()] | Ecto.Association.NotLoaded.t(),
          approved_requests: [Mydia.Media.MediaRequest.t()] | Ecto.Association.NotLoaded.t(),
          inserted_at: DateTime.t(),
          updated_at: DateTime.t()
        }

  schema "users" do
    field :username, :string
    field :username_source, :string
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
  Changeset for writing a derived username and its provenance.

  Narrow on purpose, like `role_changeset/2`. `oidc_changeset/2` would reject
  a local account with a blank username for having no `oidc_sub`, and
  `changeset/2` would demand an email and re-run password validation, so
  neither can be used to name an arbitrary account.

  The length bounds match `changeset/2` so a derived name is indistinguishable
  from a chosen one.
  """
  def username_changeset(user, attrs) do
    user
    |> cast(attrs, [:username, :username_source])
    |> validate_required([:username])
    |> validate_length(:username, min: 3, max: 50)
    |> unique_constraint(:username)
  end

  @doc """
  The name to show for a user.

  Username comes first because it is what media-server account matching keys
  on, so a local account reads exactly as it always has and the fallbacks
  engage only where the label would otherwise be blank. An OIDC-provisioned
  account has no username at all: `oidc_changeset/2` never casts the field.

  Email and display name are optional too, since OIDC requires only
  `oidc_sub`, so the last resort is an id prefix. It is ugly, but two
  otherwise-identical accounts have to be distinguishable in the
  account-mapping picker.
  """
  @spec label(t()) :: String.t()
  def label(%__MODULE__{} = user) do
    [user.username, user.display_name, user.email]
    |> Enum.find(&present?/1)
    |> case do
      nil -> id_label(user)
      value -> String.trim(value)
    end
  end

  defp present?(value), do: is_binary(value) and String.trim(value) != ""

  defp id_label(%__MODULE__{id: id}) when is_binary(id), do: "user " <> String.slice(id, 0, 8)
  defp id_label(%__MODULE__{}), do: "unknown user"

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
    |> normalize_empty_avatar_url()
    |> validate_length(:display_name, max: 100)
    |> validate_avatar_url()
  end

  defp normalize_empty_avatar_url(changeset) do
    case get_change(changeset, :avatar_url) do
      url when is_binary(url) ->
        trimmed = String.trim(url)

        if trimmed == "" do
          put_change(changeset, :avatar_url, nil)
        else
          put_change(changeset, :avatar_url, trimmed)
        end

      _ ->
        changeset
    end
  end

  defp validate_avatar_url(changeset) do
    validate_format(
      changeset,
      :avatar_url,
      ~r/^(https?:\/\/[^\s\/]+|\/generated\/avatars\/.+)/,
      message: "must be a valid URL or local avatar path"
    )
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
