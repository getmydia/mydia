defmodule Mydia.SoftAuthenticator do
  @moduledoc """
  A software WebAuthn authenticator for tests.

  Builds real `attestationObject` (fmt "none"), `authenticatorData` and
  `clientDataJSON`, and signs assertions with an ES256 key from `:crypto`, so
  `wax_` runs its full verification with nothing mocked. Payloads have the
  shape `assets/js/hooks/passkey.mjs` posts: string keys, base64url values.
  """

  defstruct [:credential_id, :private_key, :public_key, :user_handle, sign_count: 0]

  @type t :: %__MODULE__{}

  @spec new() :: t()
  def new do
    {public_key, private_key} = :crypto.generate_key(:ecdh, :secp256r1)

    %__MODULE__{
      credential_id: :crypto.strong_rand_bytes(16),
      private_key: private_key,
      public_key: public_key
    }
  end

  @spec for_user(t(), Mydia.Accounts.User.t()) :: t()
  def for_user(%__MODULE__{} = authn, user), do: %{authn | user_handle: Ecto.UUID.dump!(user.id)}

  @spec credential_id(t()) :: String.t()
  def credential_id(%__MODULE__{credential_id: id}), do: b64(id)

  @doc "Reads challenge and relying-party ID out of creation or request options."
  def ceremony(options, origin) do
    options = stringify(options)
    rp_id = get_in(options, ["rp", "id"]) || options["rpId"]
    %{challenge: options["challenge"], rp_id: rp_id, origin: origin}
  end

  @spec attest(t(), map(), keyword()) :: map()
  def attest(
        %__MODULE__{} = authn,
        %{challenge: challenge, rp_id: rp_id, origin: origin},
        opts \\ []
      ) do
    client_data =
      client_data_json("webauthn.create", challenge, Keyword.get(opts, :origin, origin))

    <<4, x::binary-size(32), y::binary-size(32)>> = authn.public_key

    cose_key =
      CBOR.encode(%{
        1 => 2,
        3 => -7,
        -1 => 1,
        -2 => %CBOR.Tag{tag: :bytes, value: x},
        -3 => %CBOR.Tag{tag: :bytes, value: y}
      })

    attested =
      <<0::128>> <> <<byte_size(authn.credential_id)::16>> <> authn.credential_id <> cose_key

    auth_data =
      authenticator_data(Keyword.get(opts, :rp_id, rp_id), flags(true, opts), authn.sign_count) <>
        attested

    attestation_object =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: auth_data}
      })

    %{
      "id" => b64(authn.credential_id),
      "rawId" => b64(authn.credential_id),
      "type" => "public-key",
      "response" => %{
        "attestationObject" => b64(attestation_object),
        "clientDataJSON" => b64(client_data),
        "transports" => ["internal"]
      }
    }
  end

  @spec assert(t(), map(), keyword()) :: {t(), map()}
  def assert(
        %__MODULE__{} = authn,
        %{challenge: challenge, rp_id: rp_id, origin: origin},
        opts \\ []
      ) do
    count = Keyword.get(opts, :sign_count, authn.sign_count + 1)
    client_data = client_data_json("webauthn.get", challenge, Keyword.get(opts, :origin, origin))
    auth_data = authenticator_data(Keyword.get(opts, :rp_id, rp_id), flags(false, opts), count)

    signature =
      :crypto.sign(
        :ecdsa,
        :sha256,
        auth_data <> :crypto.hash(:sha256, client_data),
        [authn.private_key, :secp256r1]
      )

    payload = %{
      "id" => b64(authn.credential_id),
      "rawId" => b64(authn.credential_id),
      "type" => "public-key",
      "response" => %{
        "authenticatorData" => b64(auth_data),
        "clientDataJSON" => b64(client_data),
        "signature" => b64(signature),
        "userHandle" => authn.user_handle && b64(authn.user_handle)
      }
    }

    {%{authn | sign_count: count}, payload}
  end

  # Flag bits, most significant first: ED, AT, -, BS, BE, UV, -, UP.
  defp flags(attested?, opts) do
    at = if attested?, do: 1, else: 0
    uv = if Keyword.get(opts, :user_verified, true), do: 1, else: 0
    <<0::1, at::1, 0::1, 0::1, 0::1, uv::1, 0::1, 1::1>>
  end

  defp authenticator_data(rp_id, flags, count),
    do: :crypto.hash(:sha256, rp_id) <> flags <> <<count::unsigned-big-32>>

  defp client_data_json(type, challenge, origin),
    do: Jason.encode!(%{type: type, challenge: challenge, origin: origin, crossOrigin: false})

  defp b64(bin), do: Base.url_encode64(bin, padding: false)

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
