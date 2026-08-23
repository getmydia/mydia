defmodule Mydia.Library.Structs.Quality do
  @moduledoc """
  Canonical parsed-quality struct.

  Represents quality information parsed either from a release title
  (indexer search results) or extracted from an on-disk media file.
  Provides compile-time safety for quality data, replacing plain map
  access that can silently return nil.

  Boolean release flags (`dolby_vision`, `proper`, `repack`) default to
  `false`; on-disk files simply leave them at the defaults.

  ## HDR representation

  `hdr_format` and `dolby_vision` mirror `Mydia.Library.Hdr`'s `base` and
  Dolby Vision split: a release can carry a base format and Dolby Vision at
  once (an 8.1 release is both HDR10 and Dolby Vision), or Dolby Vision
  alone with no base (profile 5). Use `hdr?/1` rather than testing
  `hdr_format` for nil.

  ## HDR Format Tiers (per TRaSH Guides)

  - Dolby Vision - highest quality, includes fallback layer
  - `:hdr10_plus` - dynamic metadata
  - `:hdr10` / `:hlg` - static metadata HDR
  - nil and no Dolby Vision (SDR) - standard dynamic range
  """

  defstruct resolution: nil,
            source: nil,
            codec: nil,
            audio: nil,
            hdr_format: nil,
            dolby_vision: false,
            proper: false,
            repack: false

  @type t :: %__MODULE__{
          resolution: String.t() | nil,
          source: String.t() | nil,
          codec: String.t() | nil,
          audio: String.t() | nil,
          hdr_format: Mydia.Library.Hdr.base(),
          dolby_vision: boolean(),
          proper: boolean(),
          repack: boolean()
        }

  @doc """
  Creates a new Quality struct from a keyword list or map.

  ## Examples

      iex> new(resolution: "1080p", source: "BluRay")
      %Quality{resolution: "1080p", source: "BluRay", proper: false, repack: false}
  """
  def new(attrs \\ []) when is_list(attrs) or is_map(attrs) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Returns an empty Quality struct (all content nil, flags false).
  """
  def empty do
    %__MODULE__{}
  end

  @doc """
  Whether this release carries any HDR signal.

  Use this rather than testing `hdr_format` for nil. A Dolby Vision profile 5
  release has no base format but is certainly not SDR.
  """
  @spec hdr?(t()) :: boolean()
  def hdr?(%__MODULE__{hdr_format: nil, dolby_vision: false}), do: false
  def hdr?(%__MODULE__{}), do: true

  @doc """
  Checks if a Quality struct is empty (all content fields are nil).
  Boolean flags other than HDR are not considered.
  """
  def empty?(%__MODULE__{} = quality) do
    quality.resolution == nil &&
      quality.source == nil &&
      quality.codec == nil &&
      quality.audio == nil &&
      not hdr?(quality)
  end

  @doc """
  Formats a Quality struct as a human-readable string.

  ## Examples

      iex> format(%Quality{resolution: "1080p", source: "BluRay", codec: "x264"})
      "1080p BluRay x264"

      iex> format(%Quality{resolution: "2160p", source: "WEB-DL", hdr_format: :hdr10, dolby_vision: true})
      "2160p WEB-DL Dolby Vision"
  """
  def format(%__MODULE__{} = quality) do
    [
      quality.resolution,
      quality.source,
      quality.codec,
      quality.audio,
      hdr_label(quality),
      if(quality.proper, do: "PROPER"),
      if(quality.repack, do: "REPACK")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  def format(nil), do: nil

  # Delegates to the one module that produces human HDR text.
  defp hdr_label(%__MODULE__{} = quality) do
    Mydia.Library.Hdr.display(%Mydia.Library.Hdr{
      base: quality.hdr_format,
      dv_profile: if(quality.dolby_vision, do: 8)
    })
  end

  @doc """
  Creates a Quality struct from a plain map with string or atom keys.

  Used to reconstruct a Quality from database-stored JSON data.
  """
  def from_map(nil), do: nil

  def from_map(map) when is_map(map) do
    raw_hdr = map["hdr_format"] || map[:hdr_format]
    {base, dv_from_string} = decode_hdr(raw_hdr)

    new(%{
      resolution: map["resolution"] || map[:resolution],
      source: map["source"] || map[:source],
      codec: map["codec"] || map[:codec],
      audio: map["audio"] || map[:audio],
      hdr_format: base,
      dolby_vision: explicit_dv(map) || dv_from_string,
      proper: map["proper"] || map[:proper] || false,
      repack: map["repack"] || map[:repack] || false
    })
  end

  # Stored JSON may hold either the canonical atom (written since the HDR
  # canonicalization) or a legacy display string such as "Dolby Vision" or
  # "DV" written before it. A legacy DV string carries no base, so it sets
  # only the boolean; leaving it to fall through to nil/false, as a naive
  # `decode_base/1` once did, silently read a legacy Dolby Vision download
  # back as SDR.
  defp decode_hdr(nil), do: {nil, false}
  defp decode_hdr(value) when is_atom(value), do: {value, false}

  defp decode_hdr(value) when is_binary(value) do
    case Mydia.Library.Hdr.from_release_token(value) do
      {:base, base} -> {base, false}
      :dolby_vision -> {nil, true}
      :unknown -> {nil, false}
    end
  end

  defp explicit_dv(map), do: map["dolby_vision"] || map[:dolby_vision] || false
end
