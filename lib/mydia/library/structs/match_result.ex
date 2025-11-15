defmodule Mydia.Library.Structs.MatchResult do
  @moduledoc """
  Represents the result of matching a parsed file to a metadata provider entry.

  This struct provides compile-time safety for metadata matching results,
  ensuring consistent data shapes across the metadata matching pipeline.

  ## Fields

  - `:provider_id` - The ID from the metadata provider (e.g., TMDB ID)
  - `:provider_type` - The provider type (e.g., `:tmdb`, `:tvdb`)
  - `:title` - The matched title from the provider
  - `:year` - The release year (if available)
  - `:match_confidence` - Confidence score (0.0 to 1.0) for the match
  - `:metadata` - Full metadata from the provider
  - `:match_type` - Type of match (`:full_match` or `:partial_match`)
  - `:partial_reason` - Reason for partial match (e.g., `:episode_not_found`)
  - `:parsed_info` - The parsed file information that was matched
  - `:from_local_db` - Whether this match came from local database
  """

  alias Mydia.Library.Structs.ParsedFileInfo
  alias Mydia.Metadata.Structs.MediaMetadata

  @enforce_keys [:provider_id, :provider_type, :title, :match_confidence, :metadata]
  defstruct [
    # Required fields
    :provider_id,
    :provider_type,
    :title,
    :match_confidence,
    :metadata,
    # Optional fields
    :year,
    :match_type,
    :partial_reason,
    :parsed_info,
    :from_local_db
  ]

  @type t :: %__MODULE__{
          provider_id: String.t(),
          provider_type: atom(),
          title: String.t(),
          year: integer() | nil,
          match_confidence: float(),
          metadata: MediaMetadata.t(),
          match_type: :full_match | :partial_match | nil,
          partial_reason: :episode_not_found | :season_not_found | nil,
          parsed_info: ParsedFileInfo.t() | nil,
          from_local_db: boolean() | nil
        }

  @doc """
  Creates a new MatchResult struct.

  ## Examples

      iex> new(
      ...>   provider_id: "27205",
      ...>   provider_type: :tmdb,
      ...>   title: "Inception",
      ...>   year: 2010,
      ...>   match_confidence: 0.95,
      ...>   metadata: %{}
      ...> )
      %MatchResult{
        provider_id: "27205",
        provider_type: :tmdb,
        title: "Inception",
        year: 2010,
        match_confidence: 0.95,
        metadata: %{}
      }
  """
  def new(attrs) do
    struct!(__MODULE__, attrs)
  end
end
