defmodule MydiaWeb.DiscoverLive.UrlParams do
  @moduledoc """
  Reads and builds Discover's URL params. Imported by
  `MydiaWeb.DiscoverLive.Index`.

  Every parser is lenient: URL params are user-typed, so anything unexpected
  falls back to a default rather than erroring.
  """

  alias Mydia.Metadata.RegionalSources

  @doc "An unknown `?type=` falls back to movies."
  def parse_media_type("tv_show"), do: :tv_show
  def parse_media_type("person"), do: :person
  def parse_media_type(_), do: :movie

  @doc "A category that does not exist for the media type falls back to trending."
  def parse_category(nil, _), do: :trending
  def parse_category("discover", _), do: :discover
  def parse_category("home", _), do: :home
  def parse_category("popular", _), do: :popular
  def parse_category("upcoming", :movie), do: :upcoming
  def parse_category("now_playing", :movie), do: :now_playing
  def parse_category("on_the_air", :tv_show), do: :on_the_air
  def parse_category("airing_today", :tv_show), do: :airing_today
  def parse_category(_, _), do: :trending

  def parse_genres_param(nil), do: []
  def parse_genres_param(""), do: []

  def parse_genres_param(genres_string) do
    genres_string
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  def parse_year_param(nil), do: nil
  def parse_year_param(""), do: nil

  def parse_year_param(year_string) do
    case Integer.parse(year_string) do
      {year, ""} when year >= 1900 and year < 2100 -> year
      _ -> nil
    end
  end

  @doc """
  A reversed range is almost always a slip, so it is read as the range the user
  meant rather than one that matches nothing.
  """
  def order_years(from, to) when is_integer(from) and is_integer(to) and from > to,
    do: {to, from}

  def order_years(from, to), do: {from, to}

  def parse_rating_param(nil), do: nil
  def parse_rating_param(""), do: nil

  def parse_rating_param(rating_string) do
    case Float.parse(rating_string) do
      {rating, _} when rating >= 0 and rating <= 10 -> rating
      _ -> nil
    end
  end

  @doc """
  A sort the media type cannot use (a movie date sort on a TV link) falls back
  to the default rather than reaching TMDB, which would ignore it (#1381).
  """
  def parse_sort(sort, sort_options, default_sort) do
    if sort == default_sort or List.keymember?(sort_options, sort, 0),
      do: sort,
      else: default_sort
  end

  @doc """
  The URL a category tab click lands on. It always opens the tab itself, so
  the country tab opens on its rows even from one of its See all grids.
  Custom and the country tab keep the filters. TMDB's fixed lists take none,
  and carrying them along would bounce the click straight back to Custom.
  """
  def tab_url_params(assigns, category) when category in ["discover", "home"],
    do: assigns |> build_url_params(category: category) |> Map.delete("source")

  def tab_url_params(assigns, "trending"), do: %{"type" => to_string(assigns.media_type)}

  def tab_url_params(assigns, category),
    do: %{"type" => to_string(assigns.media_type), "category" => category}

  @doc "The URL params for the page's current state, with `overrides` applied."
  def build_url_params(assigns, overrides) do
    params = %{"type" => to_string(assigns.media_type)}

    category = Keyword.get(overrides, :category, to_string(assigns.category))

    params =
      if category != "trending" do
        Map.put(params, "category", category)
      else
        params
      end

    params =
      case {category, assigns[:source]} do
        {"home", source} when not is_nil(source) ->
          Map.put(params, "source", RegionalSources.to_param(source))

        _ ->
          params
      end

    genre = Keyword.get(overrides, :genre)

    params =
      cond do
        genre != nil and genre != "" ->
          Map.put(params, "genre", genre)

        assigns.selected_genres != [] ->
          Map.put(params, "genre", Enum.join(assigns.selected_genres, ","))

        true ->
          params
      end

    language = Keyword.get(overrides, :language, assigns.selected_language)

    params =
      if language && language != "", do: Map.put(params, "language", language), else: params

    params =
      Enum.reduce([:year_from, :year_to], params, fn key, acc ->
        case Keyword.get(overrides, key, Map.get(assigns, key)) do
          value when value in [nil, ""] -> acc
          value -> Map.put(acc, to_string(key), to_string(value))
        end
      end)

    rating = Keyword.get(overrides, :rating, assigns.min_rating)

    params =
      if rating && rating != "", do: Map.put(params, "rating", to_string(rating)), else: params

    default_sort = assigns[:default_sort] || "popularity.desc"
    sort = Keyword.get(overrides, :sort, assigns.sort_by)
    params = if sort && sort != default_sort, do: Map.put(params, "sort", sort), else: params

    params
  end

  def parse_page_param(nil), do: 1

  def parse_page_param(page_string) do
    case Integer.parse(page_string) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end
end
