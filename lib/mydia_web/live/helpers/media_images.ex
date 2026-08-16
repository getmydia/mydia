defmodule MydiaWeb.Live.Helpers.MediaImages do
  @moduledoc """
  Image URLs for a `Mydia.Media.MediaItem`.

  Shared by the media library grid, the media detail page, and the dashboard
  recently-added rail. The search-result variants in `AddMediaLive` and
  `RequestMediaLive` take a different shape and are intentionally separate.
  """

  alias Mydia.Metadata.ImageUrl
  alias Mydia.Metadata.Structs.MediaMetadata

  @placeholder "/images/no-poster.svg"

  @doc """
  Poster URL for a media item, or a placeholder when it has no poster path.

  `size` is a TMDB image size. It defaults to `"w500"`, which is what the
  full-width library grid wants. Narrow callers should ask for something
  smaller: the dashboard rail renders 144px-wide cards and passes `"w342"`,
  matching what `DiscoverComponents.media_rail` already requests for the
  same card size.
  """
  @spec poster_url(struct(), String.t()) :: String.t()
  def poster_url(media_item, size \\ "w500") do
    case media_item.metadata do
      %MediaMetadata{poster_path: path} when is_binary(path) and path != "" ->
        ImageUrl.poster_url(path, size)

      _ ->
        @placeholder
    end
  end
end
