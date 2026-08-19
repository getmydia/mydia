defmodule Mydia.Auth.Guardian do
  @moduledoc """
  Guardian implementation for JWT token management.

  Handles encoding and decoding JWT tokens for user authentication.
  Tokens contain the user ID as the subject.
  """
  use Guardian, otp_app: :mydia

  alias Mydia.Accounts
  alias Mydia.Accounts.User

  @doc """
  Encodes the user ID into the JWT token subject.
  """
  def subject_for_token(%User{id: id}, _claims) do
    {:ok, to_string(id)}
  end

  def subject_for_token(_, _) do
    {:error, :invalid_resource}
  end

  @doc """
  Decodes the JWT token and retrieves the user from the database.
  """
  def resource_from_claims(%{"sub" => id}) do
    case Accounts.get_user!(id) do
      user -> {:ok, user}
    end
  rescue
    Ecto.NoResultsError -> {:error, :user_not_found}
  end

  def resource_from_claims(_claims) do
    {:error, :invalid_claims}
  end

  @doc """
  Creates a token for a user after successful authentication.
  """
  def create_token(user) do
    encode_and_sign(user, %{}, token_type: :access)
  end

  @doc """
  Verifies and decodes a token, returning the user.
  """
  def verify_token(token) do
    case verify_token_with_claims(token) do
      {:ok, user, _claims} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Verifies and decodes a token, returning the user alongside the raw claims.

  Device access tokens minted by `Mydia.RemoteAccess.Pairing` carry a
  `"device_id"` claim, and `resource_from_claims/1` drops it on the way to a
  `User`. Callers that need to know *which* paired device is talking, rather
  than only who it belongs to, use this instead.
  """
  def verify_token_with_claims(token) do
    with {:ok, claims} <- decode_and_verify(token),
         {:ok, user} <- resource_from_claims(claims) do
      {:ok, user, claims}
    end
  end

  @doc """
  Revokes a token (for logout).
  """
  def revoke_token(token) do
    revoke(token)
  end
end
