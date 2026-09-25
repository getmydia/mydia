defmodule Mydia.Accounts.Passkeys do
  @moduledoc """
  Persistence for WebAuthn passkeys. Call these through `Mydia.Accounts`,
  which delegates here.

  A passkey is both a passwordless sign-in and a second factor: once a user
  has one, a password sign-in also asks for it (or TOTP).
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.Accounts.{Passkey, User, WebAuthn}
  alias Mydia.Repo

  @spec list(User.t()) :: [Passkey.t()]
  def list(%User{id: user_id}) do
    Repo.all(from p in Passkey, where: p.user_id == ^user_id, order_by: [asc: p.inserted_at])
  end

  @spec any?(User.t()) :: boolean()
  def any?(%User{id: user_id}), do: Repo.exists?(from p in Passkey, where: p.user_id == ^user_id)

  @spec any?(User.t(), String.t()) :: boolean()
  def any?(%User{id: user_id}, rp_id) do
    Repo.exists?(from p in Passkey, where: p.user_id == ^user_id and p.rp_id == ^rp_id)
  end

  @spec registration_challenge(User.t(), String.t(), String.t()) :: {Wax.Challenge.t(), map()}
  def registration_challenge(%User{} = user, rp_id, origin) do
    challenge = WebAuthn.registration_challenge(rp_id, origin)
    exclude = user |> for_rp(rp_id) |> Enum.map(&descriptor/1)
    {challenge, WebAuthn.registration_options(challenge, user, exclude)}
  end

  @spec register(User.t(), Wax.Challenge.t(), map(), String.t() | nil) ::
          {:ok, Passkey.t()}
          | {:error, :already_registered | :invalid_passkey | Ecto.Changeset.t()}
  def register(%User{} = user, %Wax.Challenge{} = challenge, payload, name) do
    case WebAuthn.verify_registration(challenge, payload) do
      {:ok, verified} ->
        %Passkey{user_id: user.id}
        |> Passkey.create_changeset(Map.merge(verified, %{rp_id: challenge.rp_id, name: name}))
        |> Repo.insert()
        |> case do
          {:ok, passkey} ->
            {:ok, passkey}

          {:error, %Ecto.Changeset{errors: errors} = changeset} ->
            if Keyword.has_key?(errors, :credential_id),
              do: {:error, :already_registered},
              else: {:error, changeset}
        end

      {:error, reason} ->
        Logger.info("Passkey registration rejected: #{inspect(reason)}")
        {:error, :invalid_passkey}
    end
  end

  @spec rename(User.t(), String.t(), String.t()) ::
          {:ok, Passkey.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def rename(%User{} = user, passkey_id, name) do
    with {:ok, passkey} <- fetch_owned(user, passkey_id) do
      passkey |> Passkey.rename_changeset(%{"name" => name}) |> Repo.update()
    end
  end

  @spec delete(User.t(), String.t()) :: {:ok, Passkey.t()} | {:error, :not_found}
  def delete(%User{} = user, passkey_id) do
    with {:ok, passkey} <- fetch_owned(user, passkey_id) do
      Repo.delete(passkey)
    end
  end

  @spec delete_all(User.t()) :: :ok
  def delete_all(%User{id: user_id}) do
    Repo.delete_all(from p in Passkey, where: p.user_id == ^user_id)
    :ok
  end

  @spec authentication_challenge(String.t(), String.t(), User.t() | nil) ::
          {Wax.Challenge.t(), map()}
  def authentication_challenge(rp_id, origin, nil) do
    challenge = WebAuthn.authentication_challenge(rp_id, origin, "required")
    {challenge, WebAuthn.authentication_options(challenge, [])}
  end

  def authentication_challenge(rp_id, origin, %User{} = user) do
    challenge = WebAuthn.authentication_challenge(rp_id, origin, "preferred")
    allow = user |> for_rp(rp_id) |> Enum.map(&descriptor/1)
    {challenge, WebAuthn.authentication_options(challenge, allow)}
  end

  @doc """
  Verifies an assertion. With `user_id`, only that user's passkeys are
  considered, so a second-factor check never touches another account's
  counter. The credential must have been registered on the challenge's
  relying party.
  """
  @spec authenticate(Wax.Challenge.t(), map(), String.t() | nil) ::
          {:ok, User.t()} | {:error, :invalid_passkey}
  def authenticate(%Wax.Challenge{} = challenge, payload, user_id \\ nil) do
    with {:ok, passkey} <- fetch_for_assertion(challenge, payload, user_id),
         {:ok, %{sign_count: count, user_handle: handle}} <-
           WebAuthn.verify_authentication(
             challenge,
             payload,
             passkey.credential_id,
             Passkey.cose_key(passkey)
           ),
         :ok <- check_user_handle(handle, passkey.user_id),
         :ok <- record_use(passkey, count) do
      {:ok, Repo.get!(User, passkey.user_id)}
    else
      {:error, :sign_count_regressed} ->
        Logger.warning(
          "Passkey rejected: sign count went backwards, possible cloned authenticator " <>
            "(payload id #{inspect(payload["id"])})"
        )

        {:error, :invalid_passkey}

      {:error, reason} ->
        Logger.info("Passkey assertion rejected: #{inspect(reason)}")
        {:error, :invalid_passkey}
    end
  end

  defp fetch_for_assertion(challenge, payload, user_id) do
    with {:ok, credential_id} <- WebAuthn.credential_id(payload),
         %Passkey{} = passkey <- lookup(credential_id, user_id) do
      if passkey.rp_id == challenge.rp_id,
        do: {:ok, passkey},
        else: {:error, {:rp_id_mismatch, passkey.rp_id}}
    else
      _ -> {:error, :unknown_credential}
    end
  end

  defp lookup(credential_id, nil), do: Repo.get_by(Passkey, credential_id: credential_id)

  defp lookup(credential_id, user_id),
    do: Repo.get_by(Passkey, credential_id: credential_id, user_id: user_id)

  defp check_user_handle(nil, _user_id), do: :ok

  defp check_user_handle(handle, user_id) do
    case Ecto.UUID.load(handle) do
      {:ok, ^user_id} -> :ok
      _ -> {:error, :user_handle_mismatch}
    end
  rescue
    _ -> {:error, :user_handle_mismatch}
  end

  # A conditional UPDATE, so two concurrent assertions cannot both move the
  # counter, and a counter that did not advance matches no row. Authenticators
  # that always report 0 (most synced passkeys) are always accepted.
  defp record_use(%Passkey{id: id}, count) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    query = from p in Passkey, where: p.id == ^id

    query =
      if count == 0,
        do: where(query, [p], p.sign_count == 0),
        else: where(query, [p], p.sign_count < ^count)

    case Repo.update_all(query, set: [sign_count: count, last_used_at: now]) do
      {1, _} -> :ok
      {0, _} -> {:error, :sign_count_regressed}
    end
  end

  defp fetch_owned(%User{id: user_id}, passkey_id) do
    with {:ok, id} <- Ecto.UUID.cast(passkey_id),
         %Passkey{} = passkey <- Repo.get_by(Passkey, id: id, user_id: user_id) do
      {:ok, passkey}
    else
      _ -> {:error, :not_found}
    end
  end

  defp for_rp(%User{id: user_id}, rp_id) do
    Repo.all(from p in Passkey, where: p.user_id == ^user_id and p.rp_id == ^rp_id)
  end

  defp descriptor(%Passkey{} = passkey),
    do: %{id: passkey.credential_id, transports: Passkey.transports(passkey)}
end
