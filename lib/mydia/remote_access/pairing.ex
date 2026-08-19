defmodule Mydia.RemoteAccess.Pairing do
  @moduledoc """
  Handles device pairing validation and token generation.
  """

  require Logger

  alias Mydia.RemoteAccess
  alias Mydia.RemoteAccess.MediaToken
  alias Mydia.Auth.Guardian

  @doc """
  Completes the pairing process after claim code validation.

  This function:
  1. Validates the claim code
  2. Registers the device
  3. Generates tokens
  4. Consumes the claim code

  Returns `{:ok, device, media_token, access_token, device_token}` on success.
  """
  def complete_pairing(claim_code, device_attrs) do
    # Validate the claim code
    with {:ok, claim} <- RemoteAccess.validate_claim_code(claim_code),
         # Generate a unique device token
         device_token = generate_device_token(),
         # Register the device
         device_params =
           Map.merge(device_attrs, %{token: device_token, user_id: claim.user_id}),
         {:ok, device} <- RemoteAccess.create_device(device_params),
         # Set initial last_seen_at timestamp
         {:ok, device} <- RemoteAccess.touch_device(device),
         # Consume the claim code
         {:ok, _consumed_claim} <- RemoteAccess.consume_claim_code(claim_code, device.id) do
      # Generate tokens
      media_token = generate_media_token(device)
      access_token = generate_access_token(device)

      # Return the device, tokens, device token (for reconnection)
      {:ok, device, media_token, access_token, device_token}
    end
  end

  @doc """
  Generates a JWT media access token for the device.
  """
  def generate_media_token(device) do
    case MediaToken.create_token(device) do
      {:ok, token, _claims} -> token
      {:error, _reason} -> raise "Failed to generate media token"
    end
  end

  @doc """
  Generates a JWT access token for the device's user.
  """
  def generate_access_token(device) do
    case generate_access_token_with_claims(device) do
      {:ok, token, _claims} -> token
      {:error, reason} -> raise "Failed to generate access token: #{inspect(reason)}"
    end
  end

  @doc """
  Generates a JWT access token for the device's user, returning the claims too.

  Used by the token refresh flow, which needs the expiry to hand back to the
  client and must report failures rather than raising.
  """
  def generate_access_token_with_claims(device) do
    # Preload user if not already loaded
    device = Mydia.Repo.preload(device, :user)

    Guardian.encode_and_sign(device.user, %{
      "device_id" => device.id,
      "typ" => "access"
    })
  end

  # Generates a unique device token
  defp generate_device_token do
    :crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)
  end
end
