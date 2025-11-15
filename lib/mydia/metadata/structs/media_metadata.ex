defmodule Mydia.Metadata.Structs.MediaMetadata do
  @moduledoc """
  Represents full media metadata from TMDB via the metadata relay service.

  This struct provides compile-time safety for detailed media metadata,
  replacing plain map access that can silently return nil.

  Supports both movies and TV shows with shared and type-specific fields.
  """

  alias Mydia.Metadata.Structs.{CastMember, CrewMember, SeasonInfo}

  @enforce_keys [:provider_id, :provider, :media_type]
  defstruct [
    # Required fields
    :provider_id,
    :provider,
    :media_type,
    # Shared optional fields
    :id,
    :title,
    :original_title,
    :year,
    :release_date,
    :overview,
    :tagline,
    :runtime,
    :status,
    :genres,
    :poster_path,
    :backdrop_path,
    :popularity,
    :vote_average,
    :vote_count,
    :imdb_id,
    :production_companies,
    :production_countries,
    :spoken_languages,
    :homepage,
    :cast,
    :crew,
    :alternative_titles,
    # TV show specific fields
    :number_of_seasons,
    :number_of_episodes,
    :episode_run_time,
    :first_air_date,
    :last_air_date,
    :in_production,
    :seasons
  ]

  @type t :: %__MODULE__{
          provider_id: String.t(),
          provider: atom(),
          media_type: :movie | :tv_show,
          id: integer() | nil,
          title: String.t() | nil,
          original_title: String.t() | nil,
          year: integer() | nil,
          release_date: Date.t() | nil,
          overview: String.t() | nil,
          tagline: String.t() | nil,
          runtime: integer() | nil,
          status: String.t() | nil,
          genres: [String.t()] | nil,
          poster_path: String.t() | nil,
          backdrop_path: String.t() | nil,
          popularity: float() | nil,
          vote_average: float() | nil,
          vote_count: integer() | nil,
          imdb_id: String.t() | nil,
          production_companies: [String.t()] | nil,
          production_countries: [String.t()] | nil,
          spoken_languages: [String.t()] | nil,
          homepage: String.t() | nil,
          cast: [CastMember.t()] | nil,
          crew: [CrewMember.t()] | nil,
          alternative_titles: [String.t()] | nil,
          number_of_seasons: integer() | nil,
          number_of_episodes: integer() | nil,
          episode_run_time: [integer()] | nil,
          first_air_date: Date.t() | nil,
          last_air_date: Date.t() | nil,
          in_production: boolean() | nil,
          seasons: [SeasonInfo.t()] | nil
        }

  @doc """
  Creates a MediaMetadata struct from a raw API response map.

  ## Examples

      iex> from_api_response(%{"id" => 603, "title" => "The Matrix", ...}, :movie, "603")
      %MediaMetadata{provider_id: "603", title: "The Matrix", media_type: :movie, ...}
  """
  def from_api_response(data, media_type, provider_id) when is_map(data) do
    title = get_title(data, media_type)
    year = extract_year(data, media_type)
    release_date = parse_date(get_release_date(data, media_type))

    base_metadata = %__MODULE__{
      id: data["id"],
      provider_id: to_string(provider_id),
      provider: :metadata_relay,
      title: title,
      original_title: data["original_title"] || data["original_name"],
      year: year,
      release_date: release_date,
      media_type: media_type,
      overview: data["overview"],
      tagline: data["tagline"],
      runtime: get_runtime(data, media_type),
      status: data["status"],
      genres: parse_genres(data["genres"]),
      poster_path: data["poster_path"],
      backdrop_path: data["backdrop_path"],
      popularity: data["popularity"],
      vote_average: data["vote_average"],
      vote_count: data["vote_count"],
      imdb_id: data["imdb_id"],
      production_companies: parse_names(data["production_companies"]),
      production_countries: parse_country_codes(data["production_countries"]),
      spoken_languages: parse_language_codes(data["spoken_languages"]),
      homepage: data["homepage"],
      cast: parse_cast(data["credits"]["cast"]),
      crew: parse_crew(data["credits"]["crew"]),
      alternative_titles: parse_alternative_titles(data["alternative_titles"])
    }

    case media_type do
      :tv_show ->
        %{
          base_metadata
          | number_of_seasons: data["number_of_seasons"],
            number_of_episodes: data["number_of_episodes"],
            episode_run_time: data["episode_run_time"],
            first_air_date: parse_date(data["first_air_date"]),
            last_air_date: parse_date(data["last_air_date"]),
            in_production: data["in_production"],
            seasons: parse_seasons_list(data["seasons"])
        }

      :movie ->
        base_metadata
    end
  end

  defp get_title(data, :movie), do: data["title"] || data["name"]
  defp get_title(data, :tv_show), do: data["name"] || data["title"]
  defp get_title(data, _), do: data["title"] || data["name"]

  defp get_release_date(data, :movie), do: data["release_date"]
  defp get_release_date(data, :tv_show), do: data["first_air_date"]
  defp get_release_date(data, _), do: data["release_date"]

  defp get_runtime(data, :movie), do: data["runtime"]
  defp get_runtime(data, :tv_show), do: List.first(data["episode_run_time"] || [])
  defp get_runtime(_data, _), do: nil

  defp extract_year(_data, nil), do: nil

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

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_genres(nil), do: []
  defp parse_genres(genres) when is_list(genres), do: Enum.map(genres, & &1["name"])
  defp parse_genres(_), do: []

  defp parse_names(nil), do: []
  defp parse_names(items) when is_list(items), do: Enum.map(items, & &1["name"])
  defp parse_names(_), do: []

  defp parse_seasons_list(nil), do: []

  defp parse_seasons_list(seasons) when is_list(seasons) do
    Enum.map(seasons, &SeasonInfo.from_api_response/1)
  end

  defp parse_seasons_list(_), do: []

  defp parse_country_codes(nil), do: []

  defp parse_country_codes(countries) when is_list(countries),
    do: Enum.map(countries, & &1["iso_3166_1"])

  defp parse_country_codes(_), do: []

  defp parse_language_codes(nil), do: []

  defp parse_language_codes(languages) when is_list(languages),
    do: Enum.map(languages, & &1["iso_639_1"])

  defp parse_language_codes(_), do: []

  defp parse_cast(nil), do: []

  defp parse_cast(cast) when is_list(cast) do
    cast
    |> Enum.take(20)
    |> Enum.map(fn member ->
      CastMember.new(
        name: member["name"],
        character: member["character"],
        order: member["order"],
        profile_path: member["profile_path"]
      )
    end)
  end

  defp parse_cast(_), do: []

  defp parse_crew(nil), do: []

  defp parse_crew(crew) when is_list(crew) do
    crew
    |> Enum.filter(fn member ->
      member["job"] in ["Director", "Producer", "Writer", "Screenplay"]
    end)
    |> Enum.take(10)
    |> Enum.map(fn member ->
      CrewMember.new(
        name: member["name"],
        job: member["job"],
        department: member["department"],
        profile_path: member["profile_path"]
      )
    end)
  end

  defp parse_crew(_), do: []

  defp parse_alternative_titles(nil), do: []

  defp parse_alternative_titles(%{"titles" => titles}) when is_list(titles) do
    # Extract just the title strings, filtering out duplicates
    titles
    |> Enum.map(& &1["title"])
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp parse_alternative_titles(_), do: []
end
