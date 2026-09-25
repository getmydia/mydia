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
