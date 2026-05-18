defmodule Mydia.Library.Structs.Quality do
  @moduledoc """
  Represents quality information extracted from media filenames.

  This struct provides compile-time safety for quality data,
  replacing plain map access that can silently return nil.
  """

  defstruct [
    :resolution,
    :source,
    :codec,
    :hdr_format,
    :audio,
    :bit_depth,
    :encoder,
    :rating,
    :runtime,
    :release_tags,
    :streaming_service,
    :language,
    :hdr_profile,
    :audio_channels,
    :vmaf_score
  ]

  @type t :: %__MODULE__{
          resolution: String.t() | nil,
          source: String.t() | nil,
          codec: String.t() | nil,
          hdr_format: String.t() | nil,
          audio: String.t() | nil,
          bit_depth: String.t() | nil,
          encoder: String.t() | nil,
          rating: String.t() | nil,
          runtime: String.t() | nil,
          release_tags: String.t() | nil,
          streaming_service: String.t() | nil,
          language: String.t() | nil,
          hdr_profile: String.t() | nil,
          audio_channels: String.t() | nil,
          vmaf_score: String.t() | nil
        }

  @doc """
  Creates a new Quality struct.

  ## Examples

      iex> new(resolution: "1080p", source: "BluRay", bit_depth: "10bit", audio_channels: "5.1")
      %Quality{resolution: "1080p", source: "BluRay", codec: nil, hdr_format: nil, audio: nil, bit_depth: "10bit", encoder: nil, rating: nil, runtime: nil, release_tags: nil, streaming_service: nil, language: nil, hdr_profile: nil, audio_channels: "5.1", vmaf_score: nil}
  """
  def new(attrs \\ []) do
    struct(__MODULE__, attrs)
  end

  @doc """
  Returns an empty Quality struct.
  """
  def empty do
    %__MODULE__{}
  end

  @doc """
  Checks if a Quality struct is empty (all fields are nil).
  """
  def empty?(%__MODULE__{} = quality) do
    quality
    |> Map.from_struct()
    |> Map.values()
    |> Enum.all?(&is_nil/1)
  end
end
