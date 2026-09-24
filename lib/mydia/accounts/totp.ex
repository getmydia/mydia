defmodule Mydia.Accounts.Totp do
  @moduledoc """
  Pure TOTP (RFC 6238) helpers: secrets, code checks, secret encryption at rest,
  and recovery code generation. No database access; `Mydia.Accounts` owns
  persistence.

  Codes are checked against the current 30-second step and the one before it,
  so a phone clock a few seconds behind still works. A step at or before
  `last_used_at` is rejected, which blocks replaying a code that was already
  accepted.

  The secret is encrypted with a key derived from the endpoint's
  `secret_key_base`. Rotating that key makes stored secrets undecryptable;
  recovery codes are hashed independently and keep working.
  """

  alias Plug.Crypto.{KeyGenerator, MessageEncryptor}

  @issuer "Mydia"
  @period 30
  @recovery_code_count 10
  @encryption_salt "user totp secret"
  @signing_salt "user totp secret signing"

  @spec generate_secret() :: binary()
  def generate_secret, do: NimbleTOTP.secret()

  @spec otpauth_uri(String.t(), binary()) :: String.t()
  def otpauth_uri(label, secret) do
    NimbleTOTP.otpauth_uri("#{@issuer}:#{label}", secret, issuer: @issuer)
  end

  @spec encrypt(binary()) :: String.t()
  def encrypt(secret) when is_binary(secret) do
    {encryption_key, signing_key} = keys()
    MessageEncryptor.encrypt(secret, encryption_key, signing_key)
  end

  @spec decrypt(String.t() | nil) :: {:ok, binary()} | :error
  def decrypt(ciphertext) when is_binary(ciphertext) do
    {encryption_key, signing_key} = keys()
    MessageEncryptor.decrypt(ciphertext, encryption_key, signing_key)
  end

  def decrypt(_ciphertext), do: :error

  @spec valid_code?(binary(), String.t(), DateTime.t() | nil, integer()) ::
          {:ok, DateTime.t()} | :error
  def valid_code?(secret, code, last_used_at, now \\ System.os_time(:second)) do
    current = div(now, @period) * @period

    [current, current - @period]
    |> Enum.reject(&replayed?(&1, last_used_at))
    |> Enum.find(
      &Plug.Crypto.secure_compare(NimbleTOTP.verification_code(secret, time: &1), code)
    )
    |> case do
      nil -> :error
      step -> {:ok, DateTime.from_unix!(step)}
    end
  end

  defp replayed?(_step, nil), do: false
  defp replayed?(step, %DateTime{} = last_used_at), do: step <= DateTime.to_unix(last_used_at)

  @spec generate_recovery_codes() :: [String.t()]
  def generate_recovery_codes do
    for _ <- 1..@recovery_code_count do
      raw =
        7
        |> :crypto.strong_rand_bytes()
        |> Base.encode32(case: :lower, padding: false)
        |> binary_part(0, 10)

      binary_part(raw, 0, 5) <> "-" <> binary_part(raw, 5, 5)
    end
  end

  @spec normalize_code(String.t()) :: String.t()
  def normalize_code(code) when is_binary(code) do
    code
    |> String.replace(~r/[\s-]/u, "")
    |> String.downcase()
  end

  @spec code_kind(String.t()) :: :totp | :recovery | :invalid
  def code_kind(normalized) do
    cond do
      Regex.match?(~r/\A\d{6}\z/, normalized) -> :totp
      Regex.match?(~r/\A[a-z2-7]{10}\z/, normalized) -> :recovery
      true -> :invalid
    end
  end

  defp keys do
    base = Application.fetch_env!(:mydia, MydiaWeb.Endpoint)[:secret_key_base]
    {KeyGenerator.generate(base, @encryption_salt), KeyGenerator.generate(base, @signing_salt)}
  end
end
