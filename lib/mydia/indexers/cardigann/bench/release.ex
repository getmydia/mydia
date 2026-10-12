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
  """
  @spec from_prowlarr(map()) :: t()
  def from_prowlarr(%{} = json) do
    magnet = blank_to_nil(json["magnetUrl"])
    download = blank_to_nil(json["downloadUrl"])

    %__MODULE__{
      title: json["title"],
      size: json["size"],
      info_hash: normalize_hash(json["infoHash"]) || hash_from_magnet(magnet),
      download_url: download || magnet,
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

  defp normalize_hash(hash) when is_binary(hash) and hash != "", do: String.downcase(hash)
  defp normalize_hash(_), do: nil

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil

  defp parse_date(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end

  defp parse_date(_), do: nil
end
