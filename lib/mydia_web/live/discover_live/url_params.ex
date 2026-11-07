defmodule MydiaWeb.DiscoverLive.UrlParams do
  @moduledoc """
  Reads Discover's URL params. Imported by `MydiaWeb.DiscoverLive.Index`.

  Every parser is lenient: URL params are user-typed, so anything unexpected
  falls back to a default rather than erroring.
  """

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

  def parse_page_param(nil), do: 1

  def parse_page_param(page_string) do
    case Integer.parse(page_string) do
      {page, ""} when page > 0 -> page
      _ -> 1
    end
  end
end
