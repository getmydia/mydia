defmodule Mydia.Plugins.Index.Signature do
  @moduledoc """
  Verifies minisign signatures over plugin catalogs. Pure: no I/O.

  A public key is `"Ed" <> key_id(8) <> ed25519_key(32)`, base64. A signature
  file has four lines: an untrusted comment, `alg <> key_id <> signature(64)`
  in base64, `trusted comment: <text>`, and a global signature over
  `signature <> text`. `alg` is `Ed` (signs the body) or `ED` (signs the
  BLAKE2b-512 of the body, the CLI default since 0.10). Both are accepted.
  """

  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Index.PublicKey

  @spec parse_public_key(String.t() | nil) :: {:ok, PublicKey.t()} | {:error, Error.t()}
  def parse_public_key(text) when is_binary(text) do
    line =
      text
      |> String.split("\n", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "untrusted comment:")))
      |> List.first("")

    case Base.decode64(line) do
      {:ok, <<"Ed", key_id::binary-size(8), key::binary-size(32)>>} ->
        {:ok, %PublicKey{key_id: key_id, key: key, encoded: line}}

      _ ->
        invalid_key()
    end
  end

  def parse_public_key(_), do: invalid_key()

  @doc "The key id as minisign prints it: 16 uppercase hex digits, little-endian."
  @spec fingerprint(PublicKey.t()) :: String.t()
  def fingerprint(%PublicKey{key_id: key_id}) do
    key_id |> :binary.bin_to_list() |> Enum.reverse() |> :binary.list_to_bin() |> Base.encode16()
  end

  @spec verify(binary(), String.t(), PublicKey.t()) :: :ok | {:error, Error.t()}
  def verify(body, minisig, %PublicKey{} = key) when is_binary(body) and is_binary(minisig) do
    with {:ok, alg, key_id, sig, trusted, global} <- parse_signature(minisig),
         :ok <- same_key(key_id, key),
         :ok <- check(signed_message(alg, body), sig, key, "signature does not match"),
         :ok <- check(sig <> trusted, global, key, "trusted comment signature does not match") do
      :ok
    end
  end

  defp parse_signature(text) do
    lines = text |> String.split("\n", trim: true) |> Enum.map(&String.trim_trailing(&1, "\r"))

    with ["untrusted comment:" <> _, sig_line, "trusted comment: " <> trusted, global_line | _] <-
           lines,
         {:ok, <<alg::binary-size(2), key_id::binary-size(8), sig::binary-size(64)>>}
         when alg in ["Ed", "ED"] <- Base.decode64(sig_line),
         {:ok, <<global::binary-size(64)>>} <- Base.decode64(global_line) do
      {:ok, alg, key_id, sig, trusted, global}
    else
      _ -> invalid_signature("signature file is malformed")
    end
  end

  defp same_key(key_id, %PublicKey{key_id: key_id}), do: :ok
  defp same_key(_other, _key), do: invalid_signature("signed by a different key")

  defp signed_message("ED", body), do: :crypto.hash(:blake2b, body)
  defp signed_message("Ed", body), do: body

  defp check(message, sig, %PublicKey{key: key}, reason) do
    if :crypto.verify(:eddsa, :none, message, sig, [key, :ed25519]),
      do: :ok,
      else: invalid_signature(reason)
  end

  defp invalid_key, do: {:error, Error.new(:invalid_config, "not a minisign public key")}
  defp invalid_signature(reason), do: {:error, Error.new(:signature_invalid, reason)}
end
