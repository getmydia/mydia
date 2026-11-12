defmodule Mydia.Metadata.Structs.PersonCredit do
  @moduledoc """
  One title in a person's TMDB filmography.

  `media_type` is part of the identity: a movie and a show can share a TMDB id.
  """

  alias Mydia.Metadata.Structs.SearchResult

  @enforce_keys [:tmdb_id, :media_type]
  defstruct [
    :tmdb_id,
    :media_type,
    :title,
    :year,
    :date,
    :character,
    :episode_count,
    :poster_path,
    :backdrop_path,
    :overview,
    :original_language,
    :vote_average,
    :vote_count,
    genre_ids: [],
    origin_country: []
  ]

  @type t :: %__MODULE__{
          tmdb_id: integer(),
          media_type: :movie | :tv_show,
          title: String.t() | nil,
          year: integer() | nil,
          date: Date.t() | nil,
          character: String.t() | nil,
          episode_count: integer() | nil,
          poster_path: String.t() | nil,
          backdrop_path: String.t() | nil,
          overview: String.t() | nil,
          original_language: String.t() | nil,
          vote_average: float() | nil,
          vote_count: non_neg_integer() | nil,
          genre_ids: [integer()],
          origin_country: [String.t()]
        }

  @doc """
  Builds a credit from a raw TMDB combined-credits cast entry.

  Returns `nil` for entries without an id, a usable media type or a title.
  """
  @spec from_api_response(map()) :: t() | nil
  def from_api_response(%{"id" => id, "media_type" => type} = data)
      when is_integer(id) and type in ["movie", "tv"] do
    media_type = if type == "movie", do: :movie, else: :tv_show
    title = if media_type == :movie, do: data["title"], else: data["name"]

    date =
      parse_date(if media_type == :movie, do: data["release_date"], else: data["first_air_date"])

    if is_binary(title) and title != "" do
      %__MODULE__{
        tmdb_id: id,
        media_type: media_type,
        title: title,
        year: date && date.year,
        date: date,
        character: blank_to_nil(data["character"]),
        episode_count: data["episode_count"],
        poster_path: data["poster_path"],
        backdrop_path: data["backdrop_path"],
        overview: data["overview"],
        original_language: data["original_language"],
        vote_average: data["vote_average"],
        vote_count: data["vote_count"],
        genre_ids: list(data["genre_ids"]),
        origin_country: list(data["origin_country"])
      }
    end
  end

  def from_api_response(_), do: nil

  @doc """
  Converts a credit into a TMDB `SearchResult`, so the existing remote filter and
  library-status enrichment apply to filmographies unchanged.
  """
  @spec to_search_result(t()) :: SearchResult.t()
  def to_search_result(%__MODULE__{} = credit) do
    iso = credit.date && Date.to_iso8601(credit.date)

    %SearchResult{
      provider_id: Integer.to_string(credit.tmdb_id),
      provider: :tmdb,
      media_type: credit.media_type,
      title: credit.title,
      year: credit.year,
      release_date: if(credit.media_type == :movie, do: iso),
      first_air_date: if(credit.media_type == :tv_show, do: iso),
      poster_path: credit.poster_path,
      backdrop_path: credit.backdrop_path,
      overview: credit.overview,
      genre_ids: credit.genre_ids,
      origin_country: credit.origin_country,
      original_language: credit.original_language,
      vote_average: credit.vote_average
    }
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_date(_), do: nil

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_), do: nil

  defp list(value) when is_list(value), do: value
  defp list(_), do: []
end
