defmodule Mydia.Metadata.ImageUrl do
  @moduledoc """
  Centralized image URL builder for metadata providers.

  Handles both TMDB relative paths (e.g., "/abc123.jpg") and
  TVDB/other full URLs (e.g., "https://artworks.thetvdb.com/...").

  For TMDB paths, prepends the TMDB image CDN base URL with the appropriate size.
  For full URLs, returns them as-is.
  """

  @tmdb_base "https://image.tmdb.org/t/p"

  @doc """
  Builds a poster image URL.

  ## Examples

      iex> poster_url("/abc.jpg")
      "https://image.tmdb.org/t/p/w500/abc.jpg"

      iex> poster_url("https://artworks.thetvdb.com/poster.jpg")
      "https://artworks.thetvdb.com/poster.jpg"

      iex> poster_url(nil)
      nil
  """
  def poster_url(path, size \\ "w500"), do: image_url(path, size)

  @doc """
  Builds a backdrop image URL.

  Defaults to `w1280`, not `original`. TMDB originals are commonly 3840x2160,
  about 33 MB once decoded, and every consumer shows the backdrop blurred,
  dimmed or at most full-width. On the web player those decodes crowded out
  the poster grid's textures.
  """
  def backdrop_url(path, size \\ "w1280"), do: image_url(path, size)

  @doc """
  Builds a profile/cast image URL.
  """
  def profile_url(path, size \\ "w185"), do: image_url(path, size)

  @doc """
  Builds an episode still/thumbnail image URL.
  """
  def still_url(path, size \\ "w300"), do: image_url(path, size)

  @doc """
  Builds an image URL with a custom size.

  Use this when none of the specific helpers match your needs.
  Handles leading-slash normalization for TMDB paths.
  """
  def image_url(path, size \\ "original")
  def image_url(nil, _size), do: nil
  def image_url("", _size), do: nil
  def image_url("http" <> _ = url, _size), do: url

  def image_url(path, size) do
    # Ensure leading slash for TMDB relative paths
    normalized = if String.starts_with?(path, "/"), do: path, else: "/#{path}"
    "#{@tmdb_base}/#{size}#{normalized}"
  end
end
