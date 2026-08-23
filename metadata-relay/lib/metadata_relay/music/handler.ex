defmodule MetadataRelay.Music.Handler do
  @moduledoc """
  HTTP request handlers for MusicBrainz and Cover Art Archive endpoints.
  """

  alias MetadataRelay.Music.Client

  @doc """
  GET /music/search
  Search for artists, releases (albums), or recordings (tracks).
  Params:
    - query: Search query
    - type: artist | release | recording
  """
  def search(params) do
    query = Map.get(params, "query")
    type = Map.get(params, "type")

    if is_nil(query) or is_nil(type) do
      {:error, {:http_error, 400, %{error: "Missing required parameters: query, type"}}}
    else
      Client.get_mb("/#{type}", params: [query: query])
    end
  end

  @doc """
  GET /music/artist/:mbid
  Get artist details with discography (release-groups).
  """
  def get_artist(mbid, _params) do
    # inc=url-rels+genres+release-groups
    Client.get_mb("/artist/#{mbid}", params: [inc: "url-rels+genres+release-groups"])
  end

  @doc """
  GET /music/release/:mbid
  Get release details with tracks.
  """
  def get_release(mbid, _params) do
    # inc=recordings+artist-credits+labels+release-groups+genres
    Client.get_mb("/release/#{mbid}",
      params: [inc: "recordings+artist-credits+labels+release-groups+genres"]
    )
  end

  @doc """
  GET /music/release-group/:mbid
  Get release group details with releases.
  """
  def get_release_group(mbid, _params) do
    # inc=releases+artist-credits+genres
    Client.get_mb("/release-group/#{mbid}", params: [inc: "releases+artist-credits+genres"])
  end

  @doc """
  GET /music/recording/:mbid
  Get recording (track) details.
  """
  def get_recording(mbid, _params) do
    # inc=releases+artist-credits+genres
    Client.get_mb("/recording/#{mbid}", params: [inc: "releases+artist-credits+genres"])
  end

  @doc """
  GET /music/cover/:release_mbid
  Get front cover art for a release.
  """
  def get_cover_art(release_mbid) do
    # Try 500px first, then full size? Or just default.
    # CAA paths: /release/{mbid}/front
    # /release/{mbid}/front-500
    # /release/{mbid}/front-250

    # Let's try to get the 500px version as it's a good balance.
    case Client.get_caa("/release/#{release_mbid}/front-500") do
      {:ok, body} ->
        {:ok, body}

      {:error, :not_found} ->
        # Fallback to full size if 500px not found (unlikely but possible)
        Client.get_caa("/release/#{release_mbid}/front")

      other ->
        other
    end
  end
end
