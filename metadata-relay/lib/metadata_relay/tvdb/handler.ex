defmodule MetadataRelay.TVDB.Handler do
  @moduledoc """
  HTTP request handlers for TVDB API endpoints.

  Each function corresponds to a TVDB API endpoint and forwards
  the request to TVDB, returning the response.
  """

  alias MetadataRelay.TVDB.Client

  @doc """
  GET /tvdb/search
  Search for series by name.

  Parameters:
    - query: Search query string (required)
    - type: Type of result (series, movie, person) - defaults to series
    - year: Year to filter results
  """
  def search(params) do
    Client.get("/search", params: params)
  end

  @doc """
  GET /tvdb/series/{id}
  Get basic series details by ID.
  """
  def get_series(id, _params \\ []) do
    Client.get("/series/#{id}")
  end

  @doc """
  GET /tvdb/series/{id}/extended
  Get extended series details including episodes.

  Parameters:
    - meta: Metadata options (translations, episodes)
    - short: Return short format (true/false)
  """
  def get_series_extended(id, params) do
    Client.get("/series/#{id}/extended", params: params)
  end

  @doc """
  GET /tvdb/series/{id}/episodes/default
  Get all episodes for a series in default season type.

  Parameters:
    - page: Page number for pagination (0-indexed)
  """
  def get_series_episodes(id, params) do
    # TVDB v4 uses page parameter directly. `params` is the relay's
    # string-keyed param map (see Router.extract_query_params/1), so caller
    # key names never become atoms.
    page = Map.get(params, "page", 0)
    Client.get("/series/#{id}/episodes/default/page/#{page}")
  end

  @doc """
  GET /tvdb/seasons/{id}
  Get basic season details by season ID.
  """
  def get_season(id, _params \\ []) do
    Client.get("/seasons/#{id}")
  end

  @doc """
  GET /tvdb/seasons/{id}/extended
  Get extended season details including episodes.
  """
  def get_season_extended(id, params) do
    Client.get("/seasons/#{id}/extended", params: params)
  end

  @doc """
  GET /tvdb/episodes/{id}
  Get episode details by episode ID.
  """
  def get_episode(id, _params \\ []) do
    Client.get("/episodes/#{id}")
  end

  @doc """
  GET /tvdb/episodes/{id}/extended
  Get extended episode details.
  """
  def get_episode_extended(id, params) do
    Client.get("/episodes/#{id}/extended", params: params)
  end

  @doc """
  GET /tvdb/artwork/{id}
  Get artwork details by artwork ID.
  """
  def get_artwork(id, _params \\ []) do
    Client.get("/artwork/#{id}")
  end
end
