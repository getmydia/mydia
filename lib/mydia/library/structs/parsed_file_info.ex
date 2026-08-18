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
    :release_group,
    # External provider ID (extracted from folder name like [tmdb-664])
    :external_id,
    :external_provider,
    # Sample/trailer/extras detection
    # Indicates the file is a sample, trailer, or extra/bonus content
    is_sample: false,
    is_trailer: false,
    is_extra: false,
    # The method that detected this file as sample/trailer/extra
    # :filename | :folder | :duration | nil
    detection_method: nil,
    # The folder type if detected via folder (e.g., "Trailers", "Extras")
    detected_folder: nil,
    # V3 release-parser additions. Optional / nil by default so V2 callers
    # remain backward-compatible.
    #
    # `field_confidence` carries per-field parser confidence (0.0-1.0) used
    # downstream for commit / suggest threshold gating.
    #
    # `engine_flags` carries sideband signals from the parser — currently
    # `:binding_suspect`, `:parsed_title_unbound`, `:season_out_of_range`.
    # The map value type is intentionally loose (`term()`) because these
    # flags carry mixed shapes.
    field_confidence: nil,
    engine_flags: nil
  ]

  @type media_type :: :movie | :tv_show | :unknown

  @type external_provider :: :tmdb | :tvdb | :imdb | nil

  @type detection_method :: :filename | :folder | :duration | nil

  @type t :: %__MODULE__{
          type: media_type(),
          title: String.t() | nil,
          year: integer() | nil,
          season: integer() | nil,
          episodes: [integer()] | nil,
          quality: Quality.t(),
          release_group: String.t() | nil,
          confidence: float(),
          original_filename: String.t(),
          external_id: String.t() | nil,
          external_provider: external_provider(),
          is_sample: boolean(),
          is_trailer: boolean(),
          is_extra: boolean(),
          detection_method: detection_method(),
          detected_folder: String.t() | nil,
          field_confidence: %{atom() => float()} | nil,
          engine_flags: %{atom() => term()} | nil
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
      original_filename: original_filename,
      external_id: metadata[:external_id],
      external_provider: metadata[:external_provider],
      is_sample: metadata[:is_sample] || false,
      is_trailer: metadata[:is_trailer] || false,
      is_extra: metadata[:is_extra] || false,
      detection_method: metadata[:detection_method],
      detected_folder: metadata[:detected_folder],
      field_confidence: metadata[:field_confidence],
      engine_flags: metadata[:engine_flags]
    }
  end

  @doc """
  Creates a ParsedFileInfo struct with all fields from a map.

  This is a convenience function for creating structs from existing data.
  """
  def new(attrs) when is_map(attrs) do
    struct!(__MODULE__, attrs)
  end

  @doc """
  The primary (first) episode number from the `episodes` list, or `nil`.

  Multi-episode releases (e.g. S01E01E02) are matched on their first episode.
  Accepts the struct or a bare episodes list.
  """
  def primary_episode(%__MODULE__{episodes: episodes}), do: primary_episode(episodes)
  def primary_episode([first | _]), do: first
  def primary_episode(_), do: nil
end
