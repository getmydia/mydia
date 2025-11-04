defmodule Mydia.Indexers.SearchResult do
  @moduledoc """
  Normalized search result structure.

  This struct represents a torrent search result from any indexer in a
  normalized format. All adapters should convert their responses to this
  common structure.

  ## Fields

    * `:title` - Release title/name
    * `:size` - File size in bytes
    * `:seeders` - Number of seeders
    * `:leechers` - Number of leechers (peers)
    * `:download_url` - Magnet link or torrent file URL
    * `:info_url` - Link to more information about the release (optional)
    * `:indexer` - Name of the indexer that returned this result
    * `:category` - Category ID from the indexer
    * `:published_at` - When the torrent was published (optional)
    * `:quality` - Parsed quality information (resolution, codec, etc.)

  ## Quality Information

  The `:quality` field contains parsed quality information extracted from
  the release title:

      %{
        resolution: "1080p" | "720p" | "2160p" | "480p" | nil,
        source: "BluRay" | "WEB-DL" | "WEBRip" | "HDTV" | nil,
        codec: "x264" | "x265" | "H.264" | "H.265" | nil,
        audio: "AAC" | "AC3" | "DTS" | "TrueHD" | nil,
        hdr: true | false,
        proper: true | false,
        repack: true | false
      }

  ## Examples

      iex> %SearchResult{
      ...>   title: "Ubuntu 22.04 LTS 1080p BluRay x264",
      ...>   size: 4_294_967_296,
      ...>   seeders: 100,
      ...>   leechers: 50,
      ...>   download_url: "magnet:?xt=urn:btih:...",
      ...>   indexer: "Prowlarr",
      ...>   category: 2000,
      ...>   quality: %{resolution: "1080p", source: "BluRay", codec: "x264"}
      ...> }
  """

  @type quality_info :: %{
          resolution: String.t() | nil,
          source: String.t() | nil,
          codec: String.t() | nil,
          audio: String.t() | nil,
          hdr: boolean(),
          proper: boolean(),
          repack: boolean()
        }

  @type t :: %__MODULE__{
          title: String.t(),
          size: non_neg_integer(),
          seeders: non_neg_integer(),
          leechers: non_neg_integer(),
          download_url: String.t(),
          info_url: String.t() | nil,
          indexer: String.t(),
          category: integer() | nil,
          published_at: DateTime.t() | nil,
          quality: quality_info() | nil
        }

  @enforce_keys [:title, :size, :seeders, :leechers, :download_url, :indexer]
  defstruct [
    :title,
    :size,
    :seeders,
    :leechers,
    :download_url,
    :info_url,
    :indexer,
    :category,
    :published_at,
    :quality
  ]

  @doc """
  Creates a new search result with default values.

  ## Examples

      iex> SearchResult.new(
      ...>   title: "Ubuntu 22.04",
      ...>   size: 1_000_000_000,
      ...>   seeders: 50,
      ...>   leechers: 10,
      ...>   download_url: "magnet:?xt=...",
      ...>   indexer: "Prowlarr"
      ...> )
      %SearchResult{...}
  """
  @spec new(keyword()) :: t()
  def new(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  Calculates the health score of a torrent based on seeders and leechers.

  Returns a value between 0.0 and 1.0, where higher is better.

  ## Examples

      iex> result = %SearchResult{seeders: 100, leechers: 50}
      iex> SearchResult.health_score(result)
      0.95

      iex> result = %SearchResult{seeders: 0, leechers: 0}
      iex> SearchResult.health_score(result)
      0.0
  """
  @spec health_score(t()) :: float()
  def health_score(%__MODULE__{seeders: seeders, leechers: leechers}) do
    total = seeders + leechers

    cond do
      total == 0 -> 0.0
      seeders == 0 -> 0.1
      true -> min(1.0, seeders / (seeders + leechers) + seeders / 100)
    end
  end

  @doc """
  Formats the file size in a human-readable format.

  ## Examples

      iex> result = %SearchResult{size: 1_073_741_824}
      iex> SearchResult.format_size(result)
      "1.0 GB"

      iex> result = %SearchResult{size: 1_048_576}
      iex> SearchResult.format_size(result)
      "1.0 MB"
  """
  @spec format_size(t()) :: String.t()
  def format_size(%__MODULE__{size: size}) do
    format_bytes(size)
  end

  @doc """
  Returns a description of the quality for display.

  ## Examples

      iex> result = %SearchResult{quality: %{resolution: "1080p", source: "BluRay", codec: "x264"}}
      iex> SearchResult.quality_description(result)
      "1080p BluRay x264"

      iex> result = %SearchResult{quality: nil}
      iex> SearchResult.quality_description(result)
      "Unknown"
  """
  @spec quality_description(t()) :: String.t()
  def quality_description(%__MODULE__{quality: nil}), do: "Unknown"

  def quality_description(%__MODULE__{quality: quality}) do
    # Build a concise quality badge focusing on the most important attributes
    parts =
      [
        quality.resolution,
        quality.source,
        quality.hdr && "HDR"
      ]
      |> Enum.filter(& &1)

    case Enum.join(parts, " ") do
      "" -> "Unknown"
      description -> description
    end
  end

  # Private helpers

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"

  defp format_bytes(bytes) when bytes < 1024 * 1024 do
    kb = bytes / 1024
    "#{Float.round(kb, 1)} KB"
  end

  defp format_bytes(bytes) when bytes < 1024 * 1024 * 1024 do
    mb = bytes / (1024 * 1024)
    "#{Float.round(mb, 1)} MB"
  end

  defp format_bytes(bytes) do
    gb = bytes / (1024 * 1024 * 1024)
    "#{Float.round(gb, 1)} GB"
  end
end
