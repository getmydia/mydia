defmodule Mydia.Indexers.Cardigann.Bench.Release do
  @moduledoc """
  Engine-neutral release shape for the Cardigann benchmark.

  Both Mydia engines (via `from_search_result/1`) and Prowlarr's search API (via
  `from_prowlarr/1`) are mapped into this struct so results can be compared
  field by field. `:peers` is the leecher count on both sides.
  """

  alias Mydia.Indexers.SearchResult

  defstruct [:title, :size, :info_hash, :download_url, :seeders, :peers, :publish_date]

  @type t :: %__MODULE__{
          title: String.t() | nil,
          size: integer() | nil,
          info_hash: String.t() | nil,
          download_url: String.t() | nil,
          seeders: integer() | nil,
          peers: integer() | nil,
          publish_date: DateTime.t() | nil
        }

  @doc "Maps a `Mydia.Indexers.SearchResult` into a release."
  @spec from_search_result(SearchResult.t()) :: t()
  def from_search_result(%SearchResult{} = r) do
    %__MODULE__{
      title: r.title,
      size: r.size,
      info_hash: metadata_hash(r.metadata) || hash_from_magnet(r.download_url),
      download_url: r.download_url,
      seeders: r.seeders,
      peers: r.leechers,
      publish_date: r.published_at
    }
  end

  @doc """
  Maps one decoded Prowlarr `ReleaseResource` JSON object (string keys) into a
  release. Field names follow `ReleaseResource.cs`.

  The oracle side carries no comparable URL: Prowlarr's `SearchController`
  rewrites `downloadUrl` and `magnetUrl` into proxy links that embed its API key
  and an encrypted target, so `download_url` is always nil and the info hash
  comes only from `infoHash`. Size 0 (Prowlarr's "unknown") becomes nil.
  """
  @spec from_prowlarr(map()) :: t()
  def from_prowlarr(%{} = json) do
    %__MODULE__{
      title: json["title"],
      size: nonzero(json["size"]),
      info_hash: normalize_hash(json["infoHash"]),
      download_url: nil,
      seeders: json["seeders"],
      peers: json["leechers"],
      publish_date: parse_date(json["publishDate"])
    }
  end

  defp metadata_hash(%{info_hash: hash}), do: normalize_hash(hash)
  defp metadata_hash(%{"info_hash" => hash}), do: normalize_hash(hash)
  defp metadata_hash(_), do: nil

  defp hash_from_magnet("magnet:" <> _ = url) do
    case Regex.run(~r/[?&]xt=urn:btih:([^&]+)/i, url) do
      [_, hash] -> normalize_hash(hash)
      _ -> nil
    end
  end

  defp hash_from_magnet(_), do: nil

  # 40-char hex is downcased; 32-char base32 (A-Z2-7) is decoded and re-encoded
  # as lowercase hex, so both btih spellings compare equal.
  defp normalize_hash(hash) when is_binary(hash) do
    hash = String.trim(hash)

    cond do
      Regex.match?(~r/\A[0-9a-fA-F]{40}\z/, hash) ->
        String.downcase(hash)

      Regex.match?(~r/\A[A-Za-z2-7]{32}\z/, hash) ->
        case Base.decode32(hash, case: :mixed, padding: false) do
          {:ok, bin} -> Base.encode16(bin, case: :lower)
          :error -> nil
        end

      true ->
        nil
    end
  end

  defp normalize_hash(_), do: nil

  defp nonzero(n) when is_integer(n) and n > 0, do: n
  defp nonzero(_), do: nil

  defp parse_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_date(_), do: nil
end
