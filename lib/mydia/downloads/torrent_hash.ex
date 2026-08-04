defmodule Mydia.Downloads.TorrentHash do
  @moduledoc """
  Utility module for extracting info hashes from torrent files and magnet links.

  The info hash is the SHA1 hash of the bencoded "info" dictionary in a torrent file.
  This hash uniquely identifies a torrent and is used by download clients to track torrents.

  ## Examples

      # Extract from torrent file binary
      {:ok, hash} = TorrentHash.extract({:file, torrent_binary})

      # Extract from magnet link
      {:ok, hash} = TorrentHash.extract({:magnet, "magnet:?xt=urn:btih:..."})

      # Extract from URL (downloads the torrent first)
      {:ok, hash} = TorrentHash.extract({:url, "https://example.com/file.torrent"})
  """

  require Logger

  alias Mydia.Downloads.Client.Error

  @type torrent_input :: {:magnet, String.t()} | {:file, binary()} | {:url, String.t()}

  # Common public trackers for DHT bootstrapping
  @public_trackers [
    "udp://tracker.opentrackr.org:1337/announce",
    "udp://open.demonii.com:1337/announce",
    "udp://open.stealth.si:80/announce",
    "udp://tracker.torrent.eu.org:451/announce",
    "udp://exodus.desync.com:6969/announce",
    "udp://tracker.dler.org:6969/announce",
    "udp://tracker.qu.ax:6969/announce",
    "udp://open.demonoid.ch:6969/announce"
  ]

  @doc """
  Extracts the info hash from a torrent input.

  Returns `{:ok, hash}` where hash is a 40-character hex string (uppercase),
  or `{:error, Error.t()}` if extraction fails.

  ## Options

    * `:case` - `:upper` (default) or `:lower` for the hex hash format
  """
  @spec extract(torrent_input(), keyword()) :: {:ok, String.t()} | {:error, Error.t()}
  def extract(input, opts \\ [])

  def extract({:magnet, magnet_link}, opts) do
    case extract_hash_from_magnet(magnet_link) do
      {:ok, hash} -> {:ok, format_hash(hash, opts)}
      {:error, reason} -> {:error, Error.invalid_torrent(reason)}
    end
  end

  def extract({:file, file_contents}, opts) do
    case extract_info_hash_from_torrent(file_contents) do
      {:ok, hash} -> {:ok, format_hash(hash, opts)}
      {:error, reason} -> {:error, Error.invalid_torrent(reason)}
    end
  end

  def extract({:url, url}, opts) do
    case download_torrent(url) do
      {:ok, torrent_data} ->
        extract({:file, torrent_data}, opts)

      {:error, reason} ->
        {:error, Error.api_error("Failed to download torrent: #{reason}")}
    end
  end

  @doc """
  Extracts the info hash from torrent file binary data.

  The info hash is the SHA1 of the bencoded "info" dictionary.
  Returns `{:ok, hash}` or `{:error, reason}`.
  """
  @spec extract_from_file(binary()) :: {:ok, String.t()} | {:error, String.t()}
  def extract_from_file(torrent_data) when is_binary(torrent_data) do
    extract_info_hash_from_torrent(torrent_data)
  end

  @doc """
  Extracts the info hash from a magnet link.

  Supports both hex-encoded (40 chars) and base32-encoded (32 chars) hashes.
  Returns `{:ok, hash}` or `{:error, reason}`.
  """
  @spec extract_from_magnet(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def extract_from_magnet(magnet_link) when is_binary(magnet_link) do
    extract_hash_from_magnet(magnet_link)
  end

  @doc """
  Returns true if the binary is a structurally valid bencoded torrent metainfo
  file — a top-level dictionary containing an `info` dictionary.

  Works regardless of bencode key order, so both classic tracker-based torrents
  (which begin with `d8:announce…`) and trackerless / DHT-only torrents
  (which begin with whichever key sorts first, often `comment` or `created by`)
  are recognised.
  """
  @spec valid_metainfo?(binary()) :: boolean()
  def valid_metainfo?(<<?d, _rest::binary>> = body) do
    match?({:ok, _, _}, find_info_dict_boundaries(body))
  end

  def valid_metainfo?(_), do: false

  @doc """
  Constructs a magnet URI from a raw info hash and title.

  Validates the hash format (40-char SHA1 hex or 64-char SHA256 hex) and appends
  common public DHT trackers for bootstrapping.

  Returns the magnet URI string, or `nil` if the hash is invalid/missing.
  """
  @spec build_magnet(String.t() | nil, String.t() | nil) :: String.t() | nil
  def build_magnet(nil, _title), do: nil
  def build_magnet("", _title), do: nil

  def build_magnet(info_hash, title) when is_binary(info_hash) do
    hash = info_hash |> String.trim() |> String.downcase()

    if Regex.match?(~r/^[a-f0-9]{40}$/, hash) or Regex.match?(~r/^[a-f0-9]{64}$/, hash) do
      encoded_title = URI.encode(title || "Unknown")

      "magnet:?xt=urn:btih:#{hash}&dn=#{encoded_title}#{tracker_params()}"
    else
      Logger.warning("Invalid info hash format: #{inspect(info_hash)}")
      nil
    end
  end

  def build_magnet(_, _), do: nil

  @doc """
  Appends the public tracker list to a magnet URI that carries none.

  Indexers hand us magnets in whatever shape they like, and several emit a bare
  `magnet:?xt=urn:btih:HASH&dn=NAME` with no `tr=` parameter at all (Bitmagnet
  always does; Prowlarr does whenever `/download` redirects to a magnet instead
  of serving a `.torrent`). Such a magnet gives the download client no way to
  find peers except DHT, so it sits at zero bytes forever on any client whose
  DHT cannot reach the swarm, and is eventually escalated by the stall detector.

  Magnets that already advertise a tracker are returned untouched, as is any
  non-magnet input. The info hash is never altered, so client-side deduplication
  keeps matching.
  """
  @spec ensure_trackers(String.t() | nil) :: String.t() | nil
  def ensure_trackers("magnet:" <> _ = magnet) do
    if tracker_param?(magnet), do: magnet, else: magnet <> tracker_params()
  end

  def ensure_trackers(other), do: other

  ## Private Functions

  defp tracker_params do
    Enum.map_join(@public_trackers, fn tracker ->
      "&tr=" <> URI.encode(tracker, &URI.char_unreserved?/1)
    end)
  end

  defp tracker_param?(magnet) do
    case String.split(magnet, "?", parts: 2) do
      [_, query] -> query |> String.split("&") |> Enum.any?(&String.starts_with?(&1, "tr="))
      _ -> false
    end
  end

  defp format_hash(hash, opts) do
    case Keyword.get(opts, :case, :upper) do
      :lower -> String.downcase(hash)
      :upper -> String.upcase(hash)
    end
  end

  defp extract_hash_from_magnet(magnet_link) do
    # Try hex-encoded hash first (40 chars)
    case Regex.run(~r/urn:btih:([a-fA-F0-9]{40})/i, magnet_link) do
      [_, hash] ->
        {:ok, String.upcase(hash)}

      _ ->
        # Try base32 encoded hash (32 chars, newer magnet format)
        case Regex.run(~r/urn:btih:([A-Z2-7]{32})/i, magnet_link) do
          [_, base32_hash] ->
            case Base.decode32(String.upcase(base32_hash)) do
              {:ok, binary} ->
                {:ok, Base.encode16(binary, case: :upper)}

              :error ->
                {:error, "Could not decode base32 hash from magnet link"}
            end

          _ ->
            {:error, "Could not extract hash from magnet link"}
        end
    end
  end

  defp download_torrent(url) do
    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        {:ok, body}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Extract the info hash from a torrent file (bencoded)
  # The info hash is the SHA1 of the bencoded "info" dictionary
  defp extract_info_hash_from_torrent(torrent_data) when is_binary(torrent_data) do
    case find_info_dict_boundaries(torrent_data) do
      {:ok, start_pos, end_pos} ->
        info_bytes = binary_part(torrent_data, start_pos, end_pos - start_pos)
        hash = :crypto.hash(:sha, info_bytes) |> Base.encode16(case: :upper)
        {:ok, hash}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Find the start and end positions of the "info" dictionary value
  defp find_info_dict_boundaries(data) do
    case :binary.match(data, "4:info") do
      {pos, 6} ->
        value_start = pos + 6

        case find_bencode_value_end(data, value_start) do
          {:ok, value_end} -> {:ok, value_start, value_end}
          error -> error
        end

      :nomatch ->
        {:error, "Could not find 'info' key in torrent file"}
    end
  end

  defp find_bencode_value_end(data, pos) when pos < byte_size(data) do
    case :binary.at(data, pos) do
      ?d -> find_dict_end(data, pos + 1, 1)
      ?l -> find_list_end(data, pos + 1, 1)
      ?i -> find_int_end(data, pos + 1)
      c when c >= ?0 and c <= ?9 -> find_string_end(data, pos)
      _ -> {:error, "Invalid bencode at position #{pos}"}
    end
  end

  defp find_bencode_value_end(_data, _pos), do: {:error, "Unexpected end of data"}

  defp find_dict_end(data, pos, depth) when pos < byte_size(data) do
    case :binary.at(data, pos) do
      ?e when depth == 1 ->
        {:ok, pos + 1}

      ?e ->
        find_dict_end(data, pos + 1, depth - 1)

      ?d ->
        find_dict_end(data, pos + 1, depth + 1)

      ?l ->
        find_dict_end(data, pos + 1, depth + 1)

      ?i ->
        case find_int_end(data, pos + 1) do
          {:ok, new_pos} -> find_dict_end(data, new_pos, depth)
          error -> error
        end

      c when c >= ?0 and c <= ?9 ->
        case find_string_end(data, pos) do
          {:ok, new_pos} -> find_dict_end(data, new_pos, depth)
          error -> error
        end

      _ ->
        {:error, "Invalid bencode in dictionary at position #{pos}"}
    end
  end

  defp find_dict_end(_data, _pos, _depth), do: {:error, "Unexpected end of dictionary"}

  defp find_list_end(data, pos, depth) when pos < byte_size(data) do
    case :binary.at(data, pos) do
      ?e when depth == 1 ->
        {:ok, pos + 1}

      ?e ->
        find_list_end(data, pos + 1, depth - 1)

      ?d ->
        find_list_end(data, pos + 1, depth + 1)

      ?l ->
        find_list_end(data, pos + 1, depth + 1)

      ?i ->
        case find_int_end(data, pos + 1) do
          {:ok, new_pos} -> find_list_end(data, new_pos, depth)
          error -> error
        end

      c when c >= ?0 and c <= ?9 ->
        case find_string_end(data, pos) do
          {:ok, new_pos} -> find_list_end(data, new_pos, depth)
          error -> error
        end

      _ ->
        {:error, "Invalid bencode in list at position #{pos}"}
    end
  end

  defp find_list_end(_data, _pos, _depth), do: {:error, "Unexpected end of list"}

  defp find_int_end(data, pos) when pos < byte_size(data) do
    case :binary.match(data, "e", scope: {pos, byte_size(data) - pos}) do
      {end_pos, 1} -> {:ok, end_pos + 1}
      :nomatch -> {:error, "Unterminated integer"}
    end
  end

  defp find_int_end(_data, _pos), do: {:error, "Unexpected end of integer"}

  defp find_string_end(data, pos) when pos < byte_size(data) do
    case :binary.match(data, ":", scope: {pos, byte_size(data) - pos}) do
      {colon_pos, 1} ->
        len_str = binary_part(data, pos, colon_pos - pos)

        case Integer.parse(len_str) do
          {len, ""} ->
            string_end = colon_pos + 1 + len

            if string_end <= byte_size(data) do
              {:ok, string_end}
            else
              {:error, "String extends beyond data"}
            end

          _ ->
            {:error, "Invalid string length"}
        end

      :nomatch ->
        {:error, "Invalid string format"}
    end
  end

  defp find_string_end(_data, _pos), do: {:error, "Unexpected end of string"}
end
