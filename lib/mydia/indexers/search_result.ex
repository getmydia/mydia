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
    * `:metadata` - Additional metadata (e.g., season pack info) (optional)
    * `:tmdb_id` - TMDB ID from indexer (optional, for ID-based matching)
    * `:imdb_id` - IMDB ID from indexer (optional, for ID-based matching)
    * `:usenet_date` - When the release was originally posted to Usenet (optional, NZB only)
    * `:nzb_completion` - Article completion ratio (0.0..1.0) reported by Usenet indexer (optional)
    * `:nzb_grabs` - Number of times this release has been grabbed (NZB popularity indicator)
    * `:guid` - Indexer-provided stable identifier for the release (optional).
      Used by the release blacklist (issue #123) to match repeat failures. When
      missing, the blacklist falls back to a SHA-256 of (indexer, title, size).

  ## Quality Information

  The `:quality` field contains parsed quality information extracted from
  the release title as a `Mydia.Library.Structs.Quality` struct:

      %Quality{
        resolution: "1080p" | "720p" | "2160p" | "480p" | nil,
        source: "BluRay" | "WEB-DL" | "WEBRip" | "HDTV" | nil,
        codec: "x264" | "x265" | "H.264" | "H.265" | nil,
        audio: "AAC" | "AC3" | "DTS" | "TrueHD" | nil,
        hdr_format: :hdr10 | :hdr10_plus | :hlg | nil,
        dolby_vision: true | false,
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

  alias Mydia.Library.Structs.Quality
  alias Mydia.Indexers.Structs.SearchResultMetadata

  @type t :: %__MODULE__{
          title: String.t(),
          size: non_neg_integer(),
          seeders: non_neg_integer() | nil,
          leechers: non_neg_integer() | nil,
          download_url: String.t(),
          info_url: String.t() | nil,
          indexer: String.t(),
          category: integer() | nil,
          published_at: DateTime.t() | nil,
          quality: Quality.t() | nil,
          metadata: SearchResultMetadata.t() | nil,
          tmdb_id: integer() | nil,
          tvdb_id: integer() | nil,
          imdb_id: String.t() | nil,
          download_protocol: :torrent | :nzb | nil,
          usenet_date: DateTime.t() | nil,
          nzb_completion: float() | nil,
          nzb_grabs: non_neg_integer() | nil,
          guid: String.t() | nil
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
    :quality,
    :metadata,
    :tmdb_id,
    :tvdb_id,
    :imdb_id,
    :download_protocol,
    :usenet_date,
    :nzb_completion,
    :nzb_grabs,
    :guid
  ]

  @info_url_schemes ~w(http https)

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
  def health_score(%__MODULE__{seeders: nil}), do: 0.0

  def health_score(%__MODULE__{seeders: seeders, leechers: leechers}) do
    leechers = leechers || 0
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
    # Build a concise quality badge including all quality attributes
    parts =
      [
        quality.resolution,
        quality.source,
        quality.codec,
        quality.audio,
        Quality.hdr?(quality) && "HDR",
        quality.proper && "PROPER",
        quality.repack && "REPACK"
      ]
      |> Enum.filter(& &1)

    case Enum.join(parts, " ") do
      "" -> "Unknown"
      description -> description
    end
  end

  @doc """
  Returns a URL safe to render as a link to the release's page on the indexer.

  Returns `nil` unless `:info_url` is an absolute `http`/`https` URL with a host
  that differs from `:download_url`.

  Indexers supply this value, and Cardigann definitions are fetched from an
  external repository, so the scheme allowlist is a security boundary: HEEx does
  not validate URL schemes, and a `javascript:` string would otherwise render as
  a live script URL. The `:download_url` check exists because Prowlarr and
  Jackett fall back to the torznab `<guid>`, which on some indexers is the
  `.torrent` link rather than a details page.

  ## Examples

      iex> result = %SearchResult{title: "T", size: 1, seeders: 1, leechers: 1,
      ...>   download_url: "magnet:?xt=urn:btih:abc", indexer: "X",
      ...>   info_url: "https://tracker.example/details/42"}
      iex> SearchResult.info_page_url(result)
      "https://tracker.example/details/42"

      iex> result = %SearchResult{title: "T", size: 1, seeders: 1, leechers: 1,
      ...>   download_url: "magnet:?xt=urn:btih:abc", indexer: "X",
      ...>   info_url: "javascript:alert(1)"}
      iex> SearchResult.info_page_url(result)
      nil
  """
  @spec info_page_url(t()) :: String.t() | nil
  def info_page_url(%__MODULE__{info_url: info_url, download_url: download_url})
      when is_binary(info_url) do
    trimmed = String.trim(info_url)

    cond do
      trimmed == "" -> nil
      trimmed == download_url -> nil
      not linkable_scheme?(trimmed) -> nil
      true -> trimmed
    end
  end

  def info_page_url(%__MODULE__{}), do: nil

  # Private helpers

  defp linkable_scheme?(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host} when scheme in @info_url_schemes ->
        is_binary(host) and host != ""

      _ ->
        false
    end
  end

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
