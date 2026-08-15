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
  """
  @spec poster_url(struct()) :: String.t()
  def poster_url(media_item) do
    case media_item.metadata do
      %MediaMetadata{poster_path: path} when is_binary(path) -> ImageUrl.poster_url(path)
      _ -> @placeholder
    end
  end
end
