defmodule Mydia.Library.Structs.ParsedFileInfo do
  @moduledoc """
  Represents the parsed information extracted from a media filename.

  This struct provides compile-time safety for file parsing results, replacing
  plain map access that can silently return nil.

  Used by the FileParser to return structured, type-safe parsing results.
  """

  alias Mydia.Library.Structs.Quality

  @enforce_keys [:type, :original_filename, :confidence]
  defstruct [
    # Required fields
    :type,
    :original_filename,
    :confidence,
    # Optional fields
    :title,
    :year,
    :season,
    :episodes,
    :quality,
    :release_group
  ]

  @type media_type :: :movie | :tv_show | :unknown

  @type t :: %__MODULE__{
          type: media_type(),
          title: String.t() | nil,
          year: integer() | nil,
          season: integer() | nil,
          episodes: [integer()] | nil,
          quality: Quality.t(),
          release_group: String.t() | nil,
          confidence: float(),
          original_filename: String.t()
        }

  @doc """
  Creates a ParsedFileInfo struct from parsed metadata.

  ## Examples

      iex> from_metadata(%{type: :movie, title: "The Matrix", year: 1999}, "movie.mkv", 0.95)
      %ParsedFileInfo{type: :movie, title: "The Matrix", year: 1999, ...}
  """
  def from_metadata(metadata, original_filename, confidence) when is_map(metadata) do
    %__MODULE__{
      type: metadata[:type] || :unknown,
      title: metadata[:title],
      year: metadata[:year],
      season: metadata[:season],
      episodes: metadata[:episodes],
      quality: metadata[:quality] || Quality.empty(),
      release_group: metadata[:release_group],
      confidence: confidence,
      original_filename: original_filename
    }
  end

  @doc """
  Creates a ParsedFileInfo struct with all fields from a map.

  This is a convenience function for creating structs from existing data.
  """
  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, attrs)
  end
end
