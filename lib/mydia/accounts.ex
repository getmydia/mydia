defmodule Mydia.Accounts do
  @moduledoc """
  The Accounts context handles users and API keys.
  """

  use Mydia.QueryHelpers.Filterable,
    function_name: :apply_user_filters,
    filters: [
      role: :eq
    ]

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  require Logger
  alias Mydia.Repo
  alias Mydia.Accounts.{User, ApiKey, UserPreference}

  @changelog_key "last_seen_changelog_version"

  ## Users

  @doc """
  Returns the list of users.

  ## Options
    - `:role` - Filter by role
    - `:preload` - List of associations to preload
  """
  def list_users(opts \\ []) do
    User
    |> apply_user_filters(opts)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Gets a single user.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the user does not exist.
  """
  def get_user!(id, opts \\ []) do
    User
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a user by username.
  """
  def get_user_by_username(username, opts \\ []) do
    User
    |> where([u], u.username == ^username)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Gets a user by email.
  """
  def get_user_by_email(email, opts \\ []) do
    User
    |> where([u], u.email == ^email)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Gets a user by OIDC subject and issuer.
  """
  def get_user_by_oidc(oidc_sub, oidc_issuer, opts \\ []) do
    User
    |> where([u], u.oidc_sub == ^oidc_sub and u.oidc_issuer == ^oidc_issuer)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Creates a user with local authentication.
  """
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Checks if any users exist in the system.
  """
  def any_users_exist? do
    Repo.exists?(User)
  end

  @doc """
  Checks if at least one admin user exists in the system.
  """
  def admin_exists? do
    User
    |> where([u], u.role == "admin")
    |> Repo.exists?()
  end

  @doc """
  Creates or updates a user from OIDC claims.

  If this is the first user in the system (no admin exists) and it's a new user,
  automatically promotes them to admin role regardless of OIDC claims.
  This ensures that production deployments with OIDC-only auth have an initial admin.
  """
  def upsert_user_from_oidc(oidc_sub, oidc_issuer, attrs) do
    case get_user_by_oidc(oidc_sub, oidc_issuer) do
      nil ->
        # New user - check if we need to auto-promote to admin
        attrs_with_oidc = Map.merge(attrs, %{oidc_sub: oidc_sub, oidc_issuer: oidc_issuer})

        final_attrs =
          if admin_exists?() do
            # Admin exists - use role from OIDC claims
            attrs_with_oidc
          else
            # No admin exists - promote this first user to admin
            Logger.info(
              "Auto-promoting first OIDC user to admin (email: #{attrs[:email] || "unknown"})"
            )

            Map.put(attrs_with_oidc, :role, "admin")
          end

        %User{}
        |> User.oidc_changeset(final_attrs)
        |> Repo.insert()

      user ->
        # Existing user - update with OIDC claims but preserve their role
        # Role should only be changed via admin action, not OIDC login
        attrs_without_role = Map.delete(attrs, :role)

        user
        |> User.oidc_changeset(attrs_without_role)
        |> Repo.update()
    end
  end

  @doc """
  Updates a user.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates only a user's role.

  Unlike `update_user/2`, this does not re-validate the full local
  changeset, so it works for OIDC-created users (which have a `nil`
  username). Intended for admin-driven role changes.
  """
  def update_user_role(%User{} = user, attrs) do
    user
    |> User.role_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates user's last login timestamp.
  """
  def update_last_login(%User{} = user) do
    user
    |> User.login_changeset()
    |> Repo.update()
  end

  @doc """
  Updates a user's password.
  """
  def update_password(%User{} = user, password) do
    user
    |> User.password_changeset(%{password: password})
    |> Repo.update()
  end

  @doc """
  Deletes a user.

  Sweeps the user's plugin connections (and their per-connection KV state) first:
  the `user_id` FK cascades the connection rows on its own, but the KV keys are
  not user-scoped, so the application sweep removes them before the cascade.
  """
  def delete_user(%User{} = user) do
    Mydia.Plugins.Connections.delete_for_user(user.id)
    Repo.delete(user)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking user changes.
  """
  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end

  @doc """
  Verifies a user's password.
  """
  def verify_password(%User{password_hash: password_hash}, password)
      when is_binary(password_hash) do
    Bcrypt.verify_pass(password, password_hash)
  end

  def verify_password(_user, _password), do: false

  ## Profile Management

  @doc """
  Checks if a user authenticated via OIDC (has an oidc_sub set).
  """
  def oidc_user?(%User{oidc_sub: nil}), do: false
  def oidc_user?(%User{oidc_sub: _}), do: true

  @doc """
  Updates a user's profile (display_name and avatar_url only).
  """
  def update_profile(%User{} = user, attrs) do
    user
    |> User.profile_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking profile changes.
  """
  def change_profile(%User{} = user, attrs \\ %{}) do
    User.profile_changeset(user, attrs)
  end

  @doc """
  Changes a user's password with current password verification.

  Returns `{:error, :invalid_password}` if the current password is incorrect.
  Returns `{:error, changeset}` if the new password is invalid.
  """
  def change_password(%User{} = user, current_password, new_password, new_password_confirmation) do
    if verify_password(user, current_password) do
      user
      |> User.password_changeset(%{
        password: new_password,
        password_confirmation: new_password_confirmation
      })
      |> Repo.update()
    else
      {:error, :invalid_password}
    end
  end

  ## User Preferences

  @doc """
  Gets a user's preferences, creating default preferences if they don't exist.
  """
  def get_user_preference!(%User{id: user_id}) do
    get_user_preference!(user_id)
  end

  def get_user_preference!(user_id) when is_binary(user_id) do
    case Repo.get_by(UserPreference, user_id: user_id) do
      nil ->
        # Create default preferences
        {:ok, pref} =
          %UserPreference{}
          |> UserPreference.changeset(%{preferences: UserPreference.defaults()})
          |> Ecto.Changeset.put_change(:user_id, user_id)
          |> Repo.insert()

        pref

      pref ->
        pref
    end
  end

  @doc """
  Updates a user's preferences.

  The attrs should be a map with string keys matching preference names.
  """
  def update_preference(%UserPreference{} = preference, attrs) do
    preference
    |> UserPreference.update_preferences_changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking preference changes.
  """
  def change_preference(%UserPreference{} = preference, attrs \\ %{}) do
    UserPreference.changeset(preference, attrs)
  end

  @doc """
  The newest changelog version this user has seen, or `nil`.

  `nil` means the user has never been shown the changelog, which includes every
  user that existed before this feature shipped.
  """
  def last_seen_changelog_version(%User{} = user) do
    pref = get_user_preference!(user)
    Map.get(pref.preferences || %{}, @changelog_key)
  end

  @doc """
  Records that the user has seen the changelog up to `version_string`.

  Only ever moves the stored value forward, so rolling a deployment back and
  upgrading again does not replay notes the user already read. An unparseable
  stored value is treated as absent and overwritten.
  """
  def mark_changelog_seen(%User{} = user, version_string) when is_binary(version_string) do
    pref = get_user_preference!(user)
    current = Map.get(pref.preferences || %{}, @changelog_key)

    if changelog_version_newer?(current, version_string) do
      update_preference(pref, %{@changelog_key => version_string})
    else
      {:ok, pref}
    end
  end

  @doc """
  Marks the user as having seen every bundled release.

  Centralises the policy shared by the changelog banner and the changelog page:
  adopt the newest bundled version, and do nothing when no notes are bundled.
  """
  def mark_changelog_seen_at_latest(%User{} = user) do
    case Mydia.Changelog.latest() do
      nil -> :ok
      latest -> mark_changelog_seen(user, latest)
    end
  end

  # An unparseable NEW version is never written. It would clobber a valid stored
  # value, and because Changelog.unseen/1 reports nothing unseen for a value it
  # cannot parse, the user's banner would be suppressed from then on rather than
  # replayed.
  defp changelog_version_newer?(current, new) do
    case Version.parse(new) do
      :error ->
        false

      {:ok, new_version} ->
        case current && Version.parse(current) do
          {:ok, current_version} -> Version.compare(new_version, current_version) == :gt
          _ -> true
        end
    end
  end

  ## API Keys

  @doc """
  Returns the list of API keys for a user.

  ## Options
    - `:preload` - List of associations to preload
  """
  def list_api_keys(user_id, opts \\ []) do
    ApiKey
    |> where([k], k.user_id == ^user_id)
    |> maybe_preload(opts[:preload])
    |> order_by([k], desc: k.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single API key.

  Raises `Ecto.NoResultsError` if the API key does not exist.
  """
  def get_api_key!(id) do
    Repo.get!(ApiKey, id)
  end

  @doc """
  Verifies an API key and returns the associated user and API key.
  Returns {:error, reason} if the key is invalid, expired, or revoked.
  """
  def verify_api_key(key) when is_binary(key) do
    # Find all API keys and verify against them
    # This is not ideal for performance but works for small numbers of keys
    # For production, consider using a more efficient lookup mechanism
    ApiKey
    |> preload(:user)
    |> Repo.all()
    |> Enum.find(fn api_key ->
      not_revoked?(api_key) and not_expired?(api_key) and
        Argon2.verify_pass(key, api_key.key_hash)
    end)
    |> case do
      nil ->
        {:error, :invalid_key}

      api_key ->
        # Update last used timestamp
        update_api_key_last_used(api_key)
        {:ok, api_key.user, api_key}
    end
  end

  def verify_api_key(_key), do: {:error, :invalid_key}

  @doc """
  Creates an API key for a user.
  Returns {:ok, api_key, plain_key} where plain_key is the unhashed key to show to the user.

  ## Options
    - `:name` - User-given name for the key (required)
    - `:permissions` - List of permissions (defaults to ["read", "write"])
    - `:expires_at` - Optional expiration datetime
  """
  def create_api_key(user_id, attrs \\ %{}) do
    # Generate API key with mydia_ak_ prefix
    plain_key = generate_api_key()

    # Extract the prefix for storage (first 8 chars after mydia_ak_)
    key_prefix = extract_key_prefix(plain_key)

    # Default permissions to read and write
    permissions = Map.get(attrs, :permissions, ["read", "write"])

    attrs_with_key =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.put(:key, plain_key)
      |> Map.put(:key_prefix, key_prefix)
      |> Map.put(:permissions, permissions)

    case %ApiKey{}
         |> ApiKey.changeset(attrs_with_key)
         |> Repo.insert() do
      {:ok, api_key} ->
        {:ok, api_key, plain_key}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  @doc """
  Revokes an API key, preventing future use.
  """
  def revoke_api_key(%ApiKey{} = api_key) do
    api_key
    |> ApiKey.revoke_changeset()
    |> Repo.update()
  end

  @doc """
  Deletes an API key.
  """
  def delete_api_key(%ApiKey{} = api_key) do
    Repo.delete(api_key)
  end

  ## Private Functions

  defp not_expired?(%ApiKey{expires_at: nil}), do: true

  defp not_expired?(%ApiKey{expires_at: expires_at}) do
    DateTime.compare(DateTime.utc_now(), expires_at) == :lt
  end

  defp not_revoked?(%ApiKey{revoked_at: nil}), do: true
  defp not_revoked?(%ApiKey{revoked_at: _}), do: false

  defp update_api_key_last_used(api_key) do
    api_key
    |> ApiKey.used_changeset()
    |> Repo.update()
  end

  # Generate a random API key with mydia_ak_ prefix
  # Format: mydia_ak_ + 32 random alphanumeric chars
  defp generate_api_key do
    random_part =
      :crypto.strong_rand_bytes(24)
      |> Base.encode64()
      |> binary_part(0, 32)
      |> String.replace(~r/[^A-Za-z0-9]/, "")
      |> String.slice(0, 32)

    # Ensure we have exactly 32 alphanumeric chars
    random_part =
      if String.length(random_part) < 32 do
        # Pad with more random chars if needed
        padding =
          :crypto.strong_rand_bytes(32)
          |> Base.encode64()
          |> String.replace(~r/[^A-Za-z0-9]/, "")

        (random_part <> padding)
        |> String.slice(0, 32)
      else
        random_part
      end

    "mydia_ak_#{random_part}"
  end

  # Extract key prefix for display (mydia_ak_ + first 8 chars)
  defp extract_key_prefix(key) do
    case String.split(key, "_", parts: 3) do
      ["mydia", "ak", rest] ->
        "mydia_ak_#{String.slice(rest, 0, 8)}"

      _other ->
        # Fallback for unexpected format
        String.slice(key, 0, 17)
    end
  end
end
