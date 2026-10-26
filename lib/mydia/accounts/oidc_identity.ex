defmodule Mydia.Accounts.OidcIdentity do
  @moduledoc """
  The OIDC identity on a user: signing in with SSO, linking it to an existing
  account and unlinking it. Call these through `Mydia.Accounts`, which
  delegates here.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.Accounts
  alias Mydia.Accounts.User
  alias Mydia.Repo

  @doc """
  Finds, links or creates the user for an OIDC sign-in and refreshes it from
  the claims. See `Mydia.Accounts.upsert_user_from_oidc/3`.
  """
  def upsert(oidc_sub, oidc_issuer, attrs) do
    case Accounts.get_user_by_oidc(oidc_sub, oidc_issuer) do
      nil -> link_or_insert(email_link_target(attrs), oidc_sub, oidc_issuer, attrs)
      user -> update_from_oidc_claims(user, attrs)
    end
  end

  defp link_or_insert(%User{} = local, oidc_sub, oidc_issuer, attrs) do
    with {:ok, linked} <- link(local, oidc_sub, oidc_issuer) do
      update_from_oidc_claims(linked, attrs)
    end
  end

  defp link_or_insert(nil, oidc_sub, oidc_issuer, attrs),
    do: insert_oidc_user(oidc_sub, oidc_issuer, attrs)

  @doc """
  Attaches an OIDC identity to an existing account.

  Accounts are never merged: an identity already on another user is refused
  with `:identity_taken`, and an account that already has an identity with
  `:already_linked`. The second check is made against the database, not the
  struct, so two sign-ins racing to link the same account cannot overwrite
  each other's identity.
  """
  def link(%User{oidc_sub: sub}, _oidc_sub, _oidc_issuer) when not is_nil(sub),
    do: {:error, :already_linked}

  def link(%User{} = user, oidc_sub, oidc_issuer) do
    case Accounts.get_user_by_oidc(oidc_sub, oidc_issuer) do
      %User{id: id} when id != user.id -> {:error, :identity_taken}
      _ -> claim_oidc_identity(user, oidc_sub, oidc_issuer)
    end
  end

  # The conditional UPDATE is the compare-and-set: it matches only while the
  # row has no identity, and it holds the row (Postgres) or the database
  # (SQLite) until commit, so a racing link waits and then matches nothing.
  # The identity itself is written through the changeset so a unique
  # violation on oidc_sub comes back as a changeset error on both adapters,
  # where update_all would raise the driver's own exception.
  defp claim_oidc_identity(user, oidc_sub, oidc_issuer) do
    unlinked = from(u in User, where: u.id == ^user.id and is_nil(u.oidc_sub))
    now = DateTime.utc_now(:second)

    Repo.transaction(fn ->
      with {1, _} <- Repo.update_all(unlinked, set: [updated_at: now]),
           {:ok, linked} <-
             user |> User.oidc_link_changeset(oidc_sub, oidc_issuer) |> Repo.update() do
        linked
      else
        {0, _} -> Repo.rollback(:already_linked)
        {:error, %Ecto.Changeset{}} -> Repo.rollback(:identity_taken)
      end
    end)
    |> case do
      {:ok, linked} ->
        Logger.info("Linked OIDC identity to user #{linked.id} (issuer: #{oidc_issuer})")
        {:ok, linked}

      error ->
        error
    end
  end

  @doc """
  Detaches the OIDC identity, unless that would leave no way to sign in.

  Refusals carry the reason from `unlink_blocker/1`.
  """
  def unlink(%User{} = user) do
    case unlink_blocker(user) do
      nil ->
        with {:ok, unlinked} <- user |> User.oidc_link_changeset(nil, nil) |> Repo.update() do
          Logger.info("Unlinked OIDC identity from user #{unlinked.id}")
          {:ok, unlinked}
        end

      reason ->
        {:error, reason}
    end
  end

  @doc """
  Why the account cannot unlink SSO, or `nil` when it can.

    * `:not_linked` - there is no identity to unlink.
    * `:local_auth_disabled` - local sign-in is off on this server, so SSO is
      the only way in for everyone.
    * `:no_local_credential` - the account has neither a password nor a
      passkey, so unlinking would leave it with no way to sign in.
  """
  @spec unlink_blocker(User.t()) ::
          nil | :not_linked | :local_auth_disabled | :no_local_credential
  def unlink_blocker(%User{oidc_sub: nil}), do: :not_linked

  def unlink_blocker(%User{} = user) do
    cond do
      not Mydia.Config.get().auth.local_enabled -> :local_auth_disabled
      Accounts.password_user?(user) or Accounts.has_passkeys?(user) -> nil
      true -> :no_local_credential
    end
  end

  @doc """
  True when the account is linked and keeps a local way to sign in after
  unlinking: local auth is enabled and it has a password or a passkey.
  """
  def can_unlink?(%User{} = user), do: unlink_blocker(user) == nil

  @doc """
  How the account signs in: `:local`, `:oidc` (SSO only) or
  `:local_and_oidc` (a local password with SSO linked).
  """
  @spec auth_method(User.t()) :: :local | :oidc | :local_and_oidc
  def auth_method(%User{} = user) do
    case {Accounts.password_user?(user), Accounts.oidc_user?(user)} do
      {true, true} -> :local_and_oidc
      {false, true} -> :oidc
      _local -> :local
    end
  end

  @doc """
  Plain-English `auth_method/1` label for command-line output. The web UI
  translates `auth_method/1` itself.
  """
  def auth_method_label(%User{} = user) do
    case auth_method(user) do
      :local_and_oidc -> "Local + SSO"
      :oidc -> "OIDC"
      :local -> "Local"
    end
  end

  # Existing user: refresh claims but preserve role. Role is only changed by
  # an admin, never by an OIDC login.
  defp update_from_oidc_claims(user, attrs) do
    attrs = attrs |> Map.delete(:role) |> Map.delete(:email_verified)

    case user |> User.oidc_changeset(attrs) |> Repo.update() do
      {:error, %Ecto.Changeset{errors: [email: _] = errors}} = error ->
        if email_taken_error?(errors), do: refresh_keeping_email(user, attrs), else: error

      result ->
        result
    end
  end

  # The IdP now reports an email another account owns. The identity is still
  # the one this account linked, so the sign-in goes ahead on the local email.
  defp refresh_keeping_email(user, attrs) do
    Logger.info(
      "Kept the local email of user #{user.id}: the SSO email belongs to another account"
    )

    user
    |> User.oidc_changeset(Map.delete(attrs, :email))
    |> Repo.update()
  end

  # The single unlinked local account whose email matches, when the operator
  # opted in and the IdP vouches for the address. Anything ambiguous is nil.
  defp email_link_target(%{email: email, email_verified: true}) when is_binary(email) do
    if Mydia.Config.get().auth.oidc_link_by_email do
      lowered = String.downcase(email)

      User
      |> where([u], fragment("lower(?)", u.email) == ^lowered)
      |> Repo.all()
      |> case do
        [%User{oidc_sub: nil} = user] -> user
        _ -> nil
      end
    end
  end

  defp email_link_target(_attrs), do: nil

  defp insert_oidc_user(oidc_sub, oidc_issuer, attrs) do
    attrs_with_oidc =
      attrs
      |> Map.delete(:email_verified)
      |> Map.merge(%{oidc_sub: oidc_sub, oidc_issuer: oidc_issuer})

    final_attrs =
      if Accounts.admin_exists?() do
        attrs_with_oidc
      else
        Logger.info(
          "Auto-promoting first OIDC user to admin (email: #{attrs[:email] || "unknown"})"
        )

        Map.put(attrs_with_oidc, :role, "admin")
      end

    %User{}
    |> User.oidc_changeset(final_attrs)
    |> Repo.insert()
    |> case do
      {:error, %Ecto.Changeset{errors: errors} = changeset} ->
        if email_taken_error?(errors), do: {:error, :email_taken}, else: {:error, changeset}

      ok ->
        ok
    end
  end

  defp email_taken_error?(errors) do
    case Keyword.get(errors, :email) do
      {_msg, opts} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end
  end
end
