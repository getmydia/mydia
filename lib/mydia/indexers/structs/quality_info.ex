defmodule Mydia.Indexers.Structs.QualityInfo do
  @moduledoc """
  Represents quality information extracted from torrent release titles.

  This struct provides compile-time safety for quality data parsed from
  indexer search results. It includes release-specific flags like PROPER
  and REPACK that are important for ranking and selection.

  ## Differences from Library.Structs.Quality

  The indexer quality info differs from library quality:
  - HDR is a boolean (detected/not detected) vs string format name
  - Includes PROPER and REPACK flags for release quality
  - Focused on torrent release naming conventions

  ## Examples

      iex> QualityInfo.new(
      ...>   resolution: "1080p",
      ...>   source: "BluRay",
      ...>   codec: "x264",
      ...>   hdr: false,
      ...>   proper: false,
      ...>   repack: false
      ...> )
      %QualityInfo{...}
  """

  defstruct [
    :resolution,
    :source,
    :codec,
    :audio,
    :hdr,
    :proper,
    :repack
  ]

  @type t :: %__MODULE__{
          resolution: String.t() | nil,
          source: String.t() | nil,
          codec: String.t() | nil,
          audio: String.t() | nil,
          hdr: boolean(),
          proper: boolean(),
          repack: boolean()
        }

  @doc """
  Creates a new QualityInfo struct.

  ## Examples

      iex> new(resolution: "1080p", source: "BluRay")
      %QualityInfo{resolution: "1080p", source: "BluRay", codec: nil, audio: nil, hdr: false, proper: false, repack: false}

      iex> new(%{resolution: "2160p", hdr: true, proper: true})
      %QualityInfo{resolution: "2160p", source: nil, codec: nil, audio: nil, hdr: true, proper: true, repack: false}
  """
  def new(attrs \\ []) when is_list(attrs) or is_map(attrs) do
    # Ensure boolean fields have defaults
    attrs =
      attrs
      |> Enum.into(%{})
      |> Map.put_new(:hdr, false)
      |> Map.put_new(:proper, false)
      |> Map.put_new(:repack, false)

    struct(__MODULE__, attrs)
  end

  @doc """
  Returns an empty QualityInfo struct with all flags set to false.
  """
  def empty do
    %__MODULE__{
      hdr: false,
      proper: false,
      repack: false
    }
  end

  @doc """
  Checks if a QualityInfo struct is empty (all fields except flags are nil).
  """
  def empty?(%__MODULE__{} = quality) do
    quality.resolution == nil &&
      quality.source == nil &&
      quality.codec == nil &&
      quality.audio == nil
  end
end
