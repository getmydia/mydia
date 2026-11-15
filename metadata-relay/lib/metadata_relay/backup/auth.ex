defmodule MetadataRelay.Backup.Auth do
  @moduledoc """
  Verifies `Authorization: MydiaSig signer=<b64url>, ts=<unix ms>, sig=<b64url>`
  on backup requests.

  The signed message is `"METHOD\\nPATH\\nhex(sha256(body))\\nTS"` with lowercase
  hex, signed with the signer's Ed25519 key. Requests more than five minutes
  away from the server clock are rejected before the signature is checked.
  """

  @max_skew_ms 300_000
  @signer_bytes 32
  @sig_bytes 64

  @type parsed :: %{signer: binary, ts: integer, sig: binary}

  @spec parse(String.t() | nil) :: {:ok, parsed} | {:error, :missing | :malformed}
  def parse(nil), do: {:error, :missing}

  def parse("MydiaSig " <> rest) do
    fields =
      rest
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.flat_map(fn part ->
        case String.split(part, "=", parts: 2) do
          [k, v] -> [{k, v}]
          _ -> []
        end
      end)
      |> Map.new()

    with {:ok, signer} <- decode(fields["signer"], @signer_bytes),
         {:ok, sig} <- decode(fields["sig"], @sig_bytes),
         {:ok, ts} <- parse_ts(fields["ts"]) do
      {:ok, %{signer: signer, ts: ts, sig: sig}}
    end
  end

  def parse(_), do: {:error, :malformed}

  @spec verify(parsed, String.t(), String.t(), binary, integer) ::
          :ok | {:error, :skew | :bad_signature}
  def verify(%{signer: signer, ts: ts, sig: sig}, method, path, body, now_ms) do
    if abs(now_ms - ts) > @max_skew_ms do
      {:error, :skew}
    else
      hash = Base.encode16(:crypto.hash(:sha256, body), case: :lower)
      msg = "#{method}\n#{path}\n#{hash}\n#{ts}"

      if :crypto.verify(:eddsa, :none, msg, sig, [signer, :ed25519]),
        do: :ok,
        else: {:error, :bad_signature}
    end
  end

  defp decode(nil, _size), do: {:error, :malformed}

  defp decode(value, size) do
    case Base.url_decode64(String.trim_trailing(value, "="), padding: false) do
      {:ok, bin} when byte_size(bin) == size -> {:ok, bin}
      _ -> {:error, :malformed}
    end
  end

  defp parse_ts(nil), do: {:error, :malformed}

  defp parse_ts(value) do
    case Integer.parse(value) do
      {ts, ""} -> {:ok, ts}
      _ -> {:error, :malformed}
    end
  end
end
