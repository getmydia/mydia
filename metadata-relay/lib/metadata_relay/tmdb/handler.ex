defmodule MetadataRelay.TMDB.Handler do
  @moduledoc """
  HTTP request handlers for TMDB API endpoints.

  Each function corresponds to a TMDB API endpoint and forwards
  the request to TMDB, returning the response.
  """

  alias MetadataRelay.TMDB.Client

  @doc """
  GET /configuration
  Returns TMDB API configuration including image base URLs.
  """
  def configuration do
    Client.get("/configuration")
  end

  @doc """
  GET /tmdb/movies/search
  Search for movies by title.
  """
  def search_movies(params) do
    Client.get("/search/movie", params: params)
  end

  @doc """
  GET /tmdb/tv/search
  Search for TV shows by title.
  """
  def search_tv(params) do
    Client.get("/search/tv", params: params)
  end

  @doc """
  GET /tmdb/movies/{id}
  Get movie details by ID.
  """
  def get_movie(id, params) do
    Client.get("/movie/#{id}", params: params)
  end

  @doc """
  GET /tmdb/tv/shows/{id}
  Get TV show details by ID.
  """
  def get_tv_show(id, params) do
    Client.get("/tv/#{id}", params: params)
  end

  @doc """
  GET /tmdb/movies/{id}/images
  Get images for a movie.
  """
  def get_movie_images(id, params) do
    Client.get("/movie/#{id}/images", params: params)
  end

  @doc """
  GET /tmdb/tv/shows/{id}/images
  Get images for a TV show.
  """
  def get_tv_images(id, params) do
    Client.get("/tv/#{id}/images", params: params)
  end

  @doc """
  GET /tmdb/tv/shows/{id}/{season_number}
  Get season details with episodes.
  """
  def get_season(show_id, season_number, params) do
    Client.get("/tv/#{show_id}/season/#{season_number}", params: params)
  end

  @doc """
  GET /tmdb/movies/trending
  Get trending movies.
  """
  def trending_movies(params) do
    Client.get("/trending/movie/week", params: params)
  end

  @doc """
  GET /tmdb/tv/trending
  Get trending TV shows.
  """
  def trending_tv(params) do
    Client.get("/trending/tv/week", params: params)
  end

  @doc """
  GET /tmdb/movies/popular
  Get popular movies.
  """
  def popular_movies(params) do
    Client.get("/movie/popular", params: params)
  end

  @doc """
  GET /tmdb/tv/popular
  Get popular TV shows.
  """
  def popular_tv(params) do
    Client.get("/tv/popular", params: params)
  end

  @doc """
  GET /tmdb/movies/upcoming
  Get upcoming movies.
  """
  def upcoming_movies(params) do
    Client.get("/movie/upcoming", params: params)
  end

  @doc """
  GET /tmdb/movies/now_playing
  Get movies currently in theatres.
  """
  def now_playing_movies(params) do
    Client.get("/movie/now_playing", params: params)
  end

  @doc """
  GET /tmdb/tv/on_the_air
  Get TV shows currently on the air.
  """
  def on_the_air_tv(params) do
    Client.get("/tv/on_the_air", params: params)
  end

  @doc """
  GET /tmdb/tv/airing_today
  Get TV shows airing today.
  """
  def airing_today_tv(params) do
    Client.get("/tv/airing_today", params: params)
  end

  @doc """
  GET /tmdb/movies/discover
  Discover movies with filters (genre, year, language, rating, sort).
  """
  def discover_movies(params) do
    Client.get("/discover/movie", params: params)
  end

  @doc """
  GET /tmdb/tv/discover
  Discover TV shows with filters (genre, year, language, rating, sort).
  """
  def discover_tv(params) do
    Client.get("/discover/tv", params: params)
  end

  @doc """
  GET /tmdb/genre/movie
  Get the list of movie genres.
  """
  def genre_movie_list(params) do
    Client.get("/genre/movie/list", params: params)
  end

  @doc """
  GET /tmdb/genre/tv
  Get the list of TV show genres.
  """
  def genre_tv_list(params) do
    Client.get("/genre/tv/list", params: params)
  end

  @doc """
  GET /tmdb/list/{id}
  Get a user-created TMDB list.
  """
  def get_list(id, params) do
    Client.get("/list/#{id}", params: params)
  end

  @doc """
  GET /tmdb/collections/{id}
  Get a movie collection (franchise) by ID.
  """
  def get_collection(id, params) do
    Client.get("/collection/#{id}", params: params)
  end
end
