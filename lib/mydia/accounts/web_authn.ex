defmodule Mydia.Accounts.WebAuthn do
  @moduledoc """
  Pure WebAuthn helpers over `wax_`: challenges, the JSON options the browser
  needs, and verification of what it sends back. No database access;
  `Mydia.Accounts.Passkeys` owns persistence.

  Binary values cross the wire as unpadded base64url. Challenges never carry
  `allow_credentials`: the caller passes the one credential it looked up to
  `verify_authentication/4`, which keeps the challenge small enough for the
  session cookie.

  `wax_` raises on some malformed client data (an unknown `type`, a challenge
  that is not base64url), so every call into it is wrapped and returns
  `{:error, reason}` instead.
  """

  alias Mydia.Accounts.User

  @timeout_seconds 300
  @algorithms [-7, -257]
  @transports ~w(usb nfc ble internal hybrid smart-card)
  @max_credential_id_length 1366

  @spec registration_challenge(String.t(), String.t()) :: Wax.Challenge.t()
  def registration_challenge(rp_id, origin) do
    Wax.new_registration_challenge(
      origin: origin,
      rp_id: rp_id,
      attestation: "none",
      user_verification: "preferred",
      verify_trust_root: false,
      timeout: @timeout_seconds
    )
  end

  @spec registration_options(Wax.Challenge.t(), User.t(), [map()]) :: map()
  def registration_options(%Wax.Challenge{} = challenge, %User{} = user, exclude) do
    %{
      challenge: encode64(challenge.bytes),
      rp: %{id: challenge.rp_id, name: "Mydia"},
      user: %{
        id: encode64(user_handle(user)),
        name: user.username,
        displayName: user.display_name || user.username
      },
      pubKeyCredParams: Enum.map(@algorithms, &%{type: "public-key", alg: &1}),
      timeout: @timeout_seconds * 1000,
      attestation: "none",
      authenticatorSelection: %{
        residentKey: "required",
        requireResidentKey: true,
        userVerification: "preferred"
      },
      excludeCredentials: Enum.map(exclude, &descriptor/1)
    }
  end

  @spec authentication_challenge(String.t(), String.t(), String.t()) :: Wax.Challenge.t()
  def authentication_challenge(rp_id, origin, user_verification)
      when user_verification in ["required", "preferred"] do
    Wax.new_authentication_challenge(
      origin: origin,
      rp_id: rp_id,
      user_verification: user_verification,
      timeout: @timeout_seconds
    )
  end

  @spec authentication_options(Wax.Challenge.t(), [map()]) :: map()
  def authentication_options(%Wax.Challenge{} = challenge, allow) do
    %{
      challenge: encode64(challenge.bytes),
      rpId: challenge.rp_id,
      timeout: @timeout_seconds * 1000,
      userVerification: challenge.user_verification,
      allowCredentials: Enum.map(allow, &descriptor/1)
    }
  end

  @spec verify_registration(Wax.Challenge.t(), map()) :: {:ok, map()} | {:error, term()}
  def verify_registration(
        %Wax.Challenge{} = challenge,
        %{"response" => %{"attestationObject" => att, "clientDataJSON" => cdj} = response}
      )
      when is_binary(att) and is_binary(cdj) do
    with {:ok, att_bin} <- decode64(att),
         {:ok, client_data} <- decode64(cdj),
         {:ok, {auth_data, _attestation}} <-
           safely(fn -> Wax.register(att_bin, client_data, challenge) end),
         %Wax.AttestedCredentialData{} = acd <-
           auth_data.attested_credential_data || {:error, :no_credential_data} do
      {:ok,
       %{
         credential_id: encode64(acd.credential_id),
         public_key: acd.credential_public_key,
         sign_count: auth_data.sign_count,
         aaguid: aaguid(Wax.AuthenticatorData.get_aaguid(auth_data)),
         transports: transports(response["transports"])
       }}
    end
  end

  def verify_registration(_challenge, _payload), do: {:error, :malformed}

  @spec credential_id(map()) :: {:ok, String.t()} | :error
  def credential_id(%{"id" => id})
      when is_binary(id) and byte_size(id) > 0 and byte_size(id) <= @max_credential_id_length,
      do: {:ok, id}

  def credential_id(_payload), do: :error

  @spec verify_authentication(Wax.Challenge.t(), map(), String.t(), map()) ::
          {:ok, %{sign_count: non_neg_integer(), user_handle: binary() | nil}}
          | {:error, term()}
  def verify_authentication(
        %Wax.Challenge{} = challenge,
        %{
          "id" => credential_id,
          "response" =>
            %{"authenticatorData" => ad, "clientDataJSON" => cdj, "signature" => sig} = response
        },
        credential_id,
        cose_key
      )
      when is_binary(ad) and is_binary(cdj) and is_binary(sig) do
    with {:ok, auth_data_bin} <- decode64(ad),
         {:ok, client_data} <- decode64(cdj),
         {:ok, signature} <- decode64(sig),
         {:ok, user_handle} <- decode_optional64(response["userHandle"]),
         {:ok, auth_data} <-
           safely(fn ->
             Wax.authenticate(credential_id, auth_data_bin, signature, client_data, challenge, [
               {credential_id, cose_key}
             ])
           end) do
      {:ok, %{sign_count: auth_data.sign_count, user_handle: user_handle}}
    end
  end

  def verify_authentication(_challenge, _payload, _credential_id, _cose_key),
    do: {:error, :malformed}

  @doc "The WebAuthn user handle: the user's UUID as 16 raw bytes."
  @spec user_handle(User.t()) :: binary()
  def user_handle(%User{id: id}), do: Ecto.UUID.dump!(id)

  defp descriptor(%{id: id} = credential),
    do: %{type: "public-key", id: id, transports: Map.get(credential, :transports, [])}

  defp safely(fun) do
    case fun.() do
      {:ok, _} = ok -> ok
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, exception}
  end

  defp aaguid(nil), do: nil
  defp aaguid(bin), do: Base.encode16(bin, case: :lower)

  defp transports(list) when is_list(list), do: Enum.filter(list, &(&1 in @transports))
  defp transports(_other), do: []

  defp encode64(bin), do: Base.url_encode64(bin, padding: false)

  defp decode64(value) when is_binary(value) do
    case Base.url_decode64(value, padding: false) do
      {:ok, bin} -> {:ok, bin}
      :error -> {:error, :malformed}
    end
  end

  defp decode_optional64(nil), do: {:ok, nil}
  defp decode_optional64(""), do: {:ok, nil}
  defp decode_optional64(value) when is_binary(value), do: decode64(value)
  defp decode_optional64(_value), do: {:error, :malformed}
end
