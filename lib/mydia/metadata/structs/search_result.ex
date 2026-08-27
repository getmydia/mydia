defmodule Mydia.Metadata.Structs.SearchResult do
  @moduledoc """
  Represents a search result from TMDB via the metadata relay service.

  This struct provides compile-time safety for search result data, replacing
  plain map access that can silently return nil.
  """

  @enforce_keys [:provider_id, :provider, :media_type]
  defstruct [
    # Required fields
    :provider_id,
    :provider,
    :media_type,
    # Optional fields
    :title,
    :name,
    :original_title,
    :original_name,
    :year,
    :release_date,
    :first_air_date,
    :poster_path,
    :backdrop_path,
    :id,
    :imdb_id,
    :overview,
    :popularity,
    :vote_average,
    :vote_count,
    :original_language,
    # Classification signals. TMDB ships these with every search and discover
    # hit, so keeping them costs no extra request and lets a caller work out a
    # title's category without fetching its full metadata.
    genre_ids: [],
    origin_country: []
  ]

  @type t :: %__MODULE__{
          provider_id: String.t(),
          provider: atom(),
          media_type: :movie | :tv_show,
          title: String.t() | nil,
          name: String.t() | nil,
          original_title: String.t() | nil,
          original_name: String.t() | nil,
          year: integer() | nil,
          release_date: Date.t() | String.t() | nil,
          first_air_date: Date.t() | String.t() | nil,
          poster_path: String.t() | nil,
          backdrop_path: String.t() | nil,
          id: integer() | nil,
          imdb_id: String.t() | nil,
          overview: String.t() | nil,
          popularity: float() | nil,
          vote_average: float() | nil,
          vote_count: integer() | nil,
          genre_ids: [integer()],
          origin_country: [String.t()],
          original_language: String.t() | nil
        }

  @doc """
  Creates a SearchResult struct from a raw API response map.

  ## Parameters

    - `data` - Raw API response map
    - `opts` - Options (optional)
      - `:media_type` - Override media type (`:movie` or `:tv_show`)
        Used when the search endpoint implies the type but the API
        response doesn't include `media_type` field.

  ## Examples

      iex> from_api_response(%{"id" => 123, "title" => "The Matrix", ...})
      %SearchResult{provider_id: "123", title: "The Matrix", ...}

      iex> from_api_response(%{"id" => 456, "name" => "Breaking Bad", ...}, media_type: :tv_show)
      %SearchResult{provider_id: "456", title: "Breaking Bad", media_type: :tv_show, ...}
  """
  def from_api_response(data, opts \\ []) when is_map(data) do
    # Use override media_type if provided, otherwise try to infer from API response
    media_type =
      case Keyword.get(opts, :media_type) do
        type when type in [:movie, :tv_show] -> type
        _ -> normalize_media_type(data["media_type"])
      end

    title = get_title(data, media_type)
    year = extract_year(data, media_type)

    %__MODULE__{
      provider_id: to_string(data["id"]),
      provider: :metadata_relay,
      title: title,
      original_title: data["original_title"] || data["original_name"],
      name: data["name"],
      original_name: data["original_name"],
      year: year,
      media_type: media_type,
      overview: data["overview"],
      poster_path: data["poster_path"],
      backdrop_path: data["backdrop_path"],
      popularity: data["popularity"],
      vote_average: data["vote_average"],
      vote_count: data["vote_count"],
      release_date: data["release_date"],
      first_air_date: data["first_air_date"],
      id: data["id"],
      imdb_id: data["imdb_id"],
      genre_ids: List.wrap(data["genre_ids"]),
      origin_country: List.wrap(data["origin_country"]),
      original_language: data["original_language"]
    }
  end

  defp normalize_media_type("movie"), do: :movie
  defp normalize_media_type("tv"), do: :tv_show
  defp normalize_media_type(_), do: :movie

  defp get_title(data, :movie), do: data["title"] || data["name"]
  defp get_title(data, :tv_show), do: data["name"] || data["title"]
  defp get_title(data, _), do: data["title"] || data["name"]

  defp extract_year(data, :movie) do
    case data["release_date"] do
      nil -> nil
      date when is_binary(date) -> extract_year_from_date(date)
      _ -> nil
    end
  end

  defp extract_year(data, :tv_show) do
    case data["first_air_date"] do
      nil -> nil
      date when is_binary(date) -> extract_year_from_date(date)
      _ -> nil
    end
  end

  defp extract_year_from_date(date_string) do
    case String.split(date_string, "-") do
      [year | _] ->
        case Integer.parse(year) do
          {year_int, ""} -> year_int
          _ -> nil
        end

      _ ->
        nil
    end
  end
end
