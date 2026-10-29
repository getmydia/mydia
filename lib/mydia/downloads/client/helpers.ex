defmodule Mydia.Downloads.Client.Helpers do
  @moduledoc """
  Shared parsing helpers for download client adapters.

  Each adapter receives client-specific shapes (qBittorrent JSON, Transmission
  RPC, SABnzbd queue items, NZBGet RPC, rTorrent XML-RPC, Blackhole file stat),
  but they all converge on the same `Mydia.Downloads.Structs.DownloadStatus`
  fields. This module owns the size and timestamp conversions so every adapter
  uses identical, well-tested arithmetic.

  State classification stays per-adapter because the state strings differ
  client-to-client; see each adapter's `parse_state/1`.
  """

  # 1 MiB. Matches the convention used by SABnzbd's `mb` field and NZBGet's
  # `FileSizeMB` field (both report mebibytes, not megabytes).
  @bytes_per_mib 1_048_576

  # Query-param keys that *may* carry an operator credential. Lowercased
  # comparison is used so `Token=` and `TOKEN=` are caught too. The tracker
  # spellings matter because a Cardigann guid is the release's download URL.
  @sensitive_url_params ~w(token auth apikey api_key agent _apikey password
                           passkey authkey rsskey torrent_pass api_token)
  @redacted_param_value URI.encode_www_form("[REDACTED]")

  # Upper bound on a `DownloadStatus.failure_detail`. Provider detail is a
  # short native token; anything longer is a payload dump that has no
  # business in a log line, an event, or the database.
  @failure_detail_max_length 200

  @doc """
  Converts a value expressed in mebibytes (MiB) into bytes.

  Accepts integers, floats, strings (parsed as floats), and `nil`. Returns an
  integer count of bytes; `nil` and unparseable input yield `0`.

  ## Examples

      iex> parse_size_mb_to_bytes(10)
      10_485_760

      iex> parse_size_mb_to_bytes(1.5)
      1_572_864

      iex> parse_size_mb_to_bytes("2.5")
      2_621_440

      iex> parse_size_mb_to_bytes(nil)
      0

      iex> parse_size_mb_to_bytes("not a number")
      0
  """
  @spec parse_size_mb_to_bytes(integer() | float() | String.t() | nil) :: integer()
  def parse_size_mb_to_bytes(value) do
    value
    |> coerce_float()
    |> Kernel.*(@bytes_per_mib)
    |> round()
  end

  @doc """
  Coerces a size value already expressed in bytes into an integer.

  Accepts integers, floats, strings, and `nil`. Returns an integer count of
  bytes; `nil` and unparseable input yield `0`.

  ## Examples

      iex> parse_size_bytes(1_048_576)
      1_048_576

      iex> parse_size_bytes(1024.5)
      1025

      iex> parse_size_bytes("2048")
      2048

      iex> parse_size_bytes(nil)
      0
  """
  @spec parse_size_bytes(integer() | float() | String.t() | nil) :: integer()
  def parse_size_bytes(value) do
    value
    |> coerce_float()
    |> round()
  end

  @doc """
  Parses a Unix epoch timestamp into a `DateTime`.

  Accepts integers, integer-shaped strings, and `nil`. Returns `nil` for `0`,
  negative values, `nil`, and unparseable input.

  ## Examples

      iex> parse_timestamp_unix(1_700_000_000)
      ~U[2023-11-14 22:13:20Z]

      iex> parse_timestamp_unix("1700000000")
      ~U[2023-11-14 22:13:20Z]

      iex> parse_timestamp_unix(0)
      nil

      iex> parse_timestamp_unix(nil)
      nil
  """
  @spec parse_timestamp_unix(integer() | String.t() | nil) :: DateTime.t() | nil
  def parse_timestamp_unix(value) when is_integer(value) and value > 0 do
    case DateTime.from_unix(value) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end

  def parse_timestamp_unix(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, ""} -> parse_timestamp_unix(int)
      _ -> nil
    end
  end

  def parse_timestamp_unix(_), do: nil

  @doc """
  Extracts the per-client `priority_profile` map from a client config map.

  Looks at the top-level `:priority_profile` key first, then falls back to
  `[:options, :priority_profile]` for the legacy nested shape. Returns an
  empty map when neither is set, so callers can pass the result straight
  into `Mydia.Downloads.Priority.resolve/3`.
  """
  @spec priority_profile(map()) :: map()
  def priority_profile(config) do
    Map.get(config, :priority_profile) || get_in(config, [:options, :priority_profile]) ||
      %{}
  end

  @doc """
  Strips credentials from a URL: the value of every credential-bearing query
  parameter, and any `user:password@` userinfo. Used everywhere a URL might
  end up in a `Logger` line, an `Error` envelope or an admin page.

  Parameters are rewritten pair by pair, so the rest of the query keeps its
  original encoding and order, repeated keys (a magnet's `tr=`) all survive,
  and a URL carrying no credentials comes back byte for byte.

  Returns the URL unchanged if parsing fails (safer to log a half-redacted
  string than to crash inside an error-handling path).
  """
  @spec redact_url(String.t() | nil) :: String.t() | nil
  def redact_url(nil), do: nil

  def redact_url(url) when is_binary(url) do
    uri = URI.parse(url)
    query = uri.query && redact_query(uri.query)

    if is_nil(uri.userinfo) and query == uri.query,
      do: url,
      else: URI.to_string(%{uri | userinfo: nil, query: query})
  rescue
    _ -> url
  end

  defp redact_query(query) do
    query
    |> String.split("&")
    |> Enum.map_join("&", fn pair ->
      [key | _] = String.split(pair, "=", parts: 2)
      if sensitive_param?(key), do: key <> "=" <> @redacted_param_value, else: pair
    end)
  end

  defp sensitive_param?(key) do
    String.downcase(URI.decode_www_form(key)) in @sensitive_url_params
  rescue
    # A malformed escape in the key; compare it as written.
    ArgumentError -> String.downcase(key) in @sensitive_url_params
  end

  @doc """
  Normalises a client-reported failure detail before it reaches a log line,
  a `download.failed` event, or the database.

  Every adapter routes its detail through here rather than sanitising
  locally, so a future adapter cannot quietly skip the redaction step.
  """
  @spec sanitize_failure_detail(String.t() | nil) :: String.t() | nil
  def sanitize_failure_detail(nil), do: nil

  def sanitize_failure_detail(detail) when is_binary(detail) do
    detail
    |> redact_url()
    |> truncate_detail()
  end

  defp truncate_detail(detail) when is_binary(detail) do
    if String.length(detail) > @failure_detail_max_length do
      String.slice(detail, 0, @failure_detail_max_length)
    else
      detail
    end
  end

  # Floors strings/numbers to a float; defaults unparseable input to 0.0.
  defp coerce_float(value) when is_float(value), do: value
  defp coerce_float(value) when is_integer(value), do: value * 1.0

  defp coerce_float(value) when is_binary(value) do
    case Float.parse(value) do
      {float, _} -> float
      :error -> 0.0
    end
  end

  defp coerce_float(_), do: 0.0
end
