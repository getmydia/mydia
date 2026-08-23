defmodule Mydia.Subtitles.Provider.SearchResult do
  @moduledoc """
  Struct representing a subtitle search result from a provider.

  This standardized format is used across all subtitle providers (relay, OpenSubtitles, etc.)
  to ensure consistent handling of search results.

  ## Fields

    * `:file_id` - Provider-specific subtitle file identifier (required)
    * `:language` - ISO 639-1 language code (e.g., "en", "es", "fr") (required)
    * `:format` - Subtitle format ("srt", "ass", "vtt", etc.) (required)
    * `:subtitle_hash` - Unique hash identifying this subtitle (required)
    * `:file_name` - Original subtitle file name (optional)
    * `:rating` - User rating (0.0-10.0 scale, nil if not available)
    * `:download_count` - Number of times this subtitle has been downloaded (optional)
    * `:hearing_impaired` - Whether subtitle includes hearing impaired annotations (default: false)
    * `:moviehash_match` - Whether this subtitle matched by file hash (default: false)
    * `:origin` - Name of the upstream this result actually came from, when the
      provider is a proxy (nil for a provider that is its own source)

  ## Examples

      # High-confidence match via file hash
      %SearchResult{
        file_id: 12345,
        language: "en",
        format: "srt",
        subtitle_hash: "abc123def456",
        file_name: "The.Matrix.1999.1080p.BluRay.srt",
        rating: 8.5,
        download_count: 5432,
        hearing_impaired: false,
        moviehash_match: true
      }

      # Metadata-based match (IMDB/TMDB)
      %SearchResult{
        file_id: 67890,
        language: "es",
        format: "srt",
        subtitle_hash: "xyz789abc123",
        file_name: "The.Matrix.1999.Spanish.srt",
        rating: 7.2,
        download_count: 1234,
        hearing_impaired: false,
        moviehash_match: false
      }

  """

  @type t :: %__MODULE__{
          file_id: integer() | String.t(),
          language: String.t(),
          format: String.t(),
          subtitle_hash: String.t(),
          file_name: String.t() | nil,
          rating: float() | nil,
          download_count: integer() | nil,
          hearing_impaired: boolean(),
          moviehash_match: boolean(),
          origin: String.t() | nil
        }

  @enforce_keys [:file_id, :language, :format, :subtitle_hash]
  defstruct [
    :file_id,
    :language,
    :format,
    :subtitle_hash,
    :file_name,
    :rating,
    :download_count,
    :origin,
    hearing_impaired: false,
    moviehash_match: false
  ]

  @doc """
  Creates a SearchResult struct from a provider-specific result map.

  Handles conversion from various provider formats to the standardized struct.

  ## Examples

      iex> from_map(%{
      ...>   "file_id" => 12345,
      ...>   "language" => "en",
      ...>   "format" => "srt",
      ...>   "subtitle_hash" => "abc123"
      ...> })
      %SearchResult{file_id: 12345, language: "en", format: "srt", subtitle_hash: "abc123"}

  """
  def from_map(map) when is_map(map) do
    %__MODULE__{
      file_id: get_field(map, "file_id") || get_field(map, :file_id),
      language: get_field(map, "language") || get_field(map, :language),
      format: get_field(map, "format") || get_field(map, :format),
      subtitle_hash: get_field(map, "subtitle_hash") || get_field(map, :subtitle_hash),
      file_name: get_field(map, "file_name") || get_field(map, :file_name),
      rating: get_field(map, "rating") || get_field(map, :rating),
      download_count: get_field(map, "download_count") || get_field(map, :download_count),
      hearing_impaired:
        get_field(map, "hearing_impaired") || get_field(map, :hearing_impaired) || false,
      moviehash_match:
        get_field(map, "moviehash_match") || get_field(map, :moviehash_match) || false,
      origin: blank_to_nil(get_field(map, "origin") || get_field(map, :origin))
    }
  end

  defp get_field(map, key), do: Map.get(map, key)

  # An empty string is truthy in Elixir, so `result.origin || config.name` in
  # `ProviderChain.tag/2` never falls back to the configured name when a relay
  # sends `"source": ""`. Blanking it here, at the boundary, keeps that `||`
  # simple instead of teaching every reader of it about this edge case.
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  @doc """
  Converts a SearchResult struct to a plain map.

  Useful for serialization and API responses.

  ## Examples

      iex> result = %SearchResult{file_id: 123, language: "en", format: "srt", subtitle_hash: "abc"}
      iex> to_map(result)
      %{
        file_id: 123,
        language: "en",
        format: "srt",
        subtitle_hash: "abc",
        file_name: nil,
        rating: nil,
        download_count: nil,
        hearing_impaired: false,
        moviehash_match: false,
        origin: nil
      }

  """
  def to_map(%__MODULE__{} = result) do
    %{
      file_id: result.file_id,
      language: result.language,
      format: result.format,
      subtitle_hash: result.subtitle_hash,
      file_name: result.file_name,
      rating: result.rating,
      download_count: result.download_count,
      hearing_impaired: result.hearing_impaired,
      moviehash_match: result.moviehash_match,
      origin: result.origin
    }
  end
end
