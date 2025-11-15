defmodule Mydia.Downloads.Structs.DownloadMetadata do
  @moduledoc """
  Represents metadata for a download that is persisted in the database.

  This metadata comes from the original search result and includes information
  about the download size, seeders/leechers (for torrents), quality, and
  season pack details (for TV shows).
  """

  @enforce_keys [:size]

  defstruct [
    :size,
    :seeders,
    :leechers,
    :quality,
    :season_pack,
    :season_number,
    :download_protocol
  ]

  @type t :: %__MODULE__{
          size: integer(),
          seeders: integer() | nil,
          leechers: integer() | nil,
          quality: String.t() | nil,
          season_pack: boolean() | nil,
          season_number: integer() | nil,
          download_protocol: :torrent | :nzb | nil
        }

  @doc """
  Creates a new DownloadMetadata struct from a map or keyword list.

  ## Examples

      iex> new(size: 1024, seeders: 10, leechers: 2)
      %DownloadMetadata{
        size: 1024,
        seeders: 10,
        leechers: 2,
        quality: nil,
        season_pack: nil,
        season_number: nil,
        download_protocol: nil
      }

      iex> new(%{size: 2048, quality: "1080p", season_pack: true, season_number: 1})
      %DownloadMetadata{
        size: 2048,
        seeders: nil,
        leechers: nil,
        quality: "1080p",
        season_pack: true,
        season_number: 1,
        download_protocol: nil
      }
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Converts a DownloadMetadata struct to a plain map for database storage.

  Handles conversion of nested structs (like QualityInfo) to plain values.

  ## Examples

      iex> metadata = new(size: 1024, seeders: 10)
      iex> to_map(metadata)
      %{size: 1024, seeders: 10, leechers: nil, quality: nil, season_pack: nil, season_number: nil, download_protocol: nil}
  """
  def to_map(%__MODULE__{} = metadata) do
    # Convert quality struct to string representation if present
    quality =
      case metadata.quality do
        %{__struct__: _} = struct ->
          # If quality is a struct (QualityInfo), convert to map
          Map.from_struct(struct)

        other ->
          other
      end

    %{
      size: metadata.size,
      seeders: metadata.seeders,
      leechers: metadata.leechers,
      quality: quality,
      season_pack: metadata.season_pack,
      season_number: metadata.season_number,
      download_protocol: metadata.download_protocol
    }
  end

  @doc """
  Creates a DownloadMetadata struct from a plain map (e.g., from database).

  Returns nil if the input is nil or an empty map.

  ## Examples

      iex> from_map(%{"size" => 1024, "seeders" => 10})
      %DownloadMetadata{size: 1024, seeders: 10, ...}

      iex> from_map(nil)
      nil
  """
  def from_map(nil), do: nil
  def from_map(map) when map == %{}, do: nil

  def from_map(map) when is_map(map) do
    # Handle case where size might not be present in old records
    size = map["size"] || map[:size] || 0

    new(%{
      size: size,
      seeders: map["seeders"] || map[:seeders],
      leechers: map["leechers"] || map[:leechers],
      quality: map["quality"] || map[:quality],
      season_pack: map["season_pack"] || map[:season_pack],
      season_number: map["season_number"] || map[:season_number],
      download_protocol: map["download_protocol"] || map[:download_protocol]
    })
  end
end
