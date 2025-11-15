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
    :audio
  ]

  @type t :: %__MODULE__{
          resolution: String.t() | nil,
          source: String.t() | nil,
          codec: String.t() | nil,
          hdr_format: String.t() | nil,
          audio: String.t() | nil
        }

  @doc """
  Creates a new Quality struct.

  ## Examples

      iex> new(resolution: "1080p", source: "BluRay")
      %Quality{resolution: "1080p", source: "BluRay", codec: nil, hdr_format: nil, audio: nil}
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
    quality.resolution == nil &&
      quality.source == nil &&
      quality.codec == nil &&
      quality.hdr_format == nil &&
      quality.audio == nil
  end
end
