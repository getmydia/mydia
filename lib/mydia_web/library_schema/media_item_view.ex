defmodule MydiaWeb.LibrarySchema.MediaItemView do
  @moduledoc """
  Turns a `%MediaItem{}` into the shape the Library API's `media_item` type reads.

  One module rather than a private helper per resolver: `lookup`'s `inLibrary` and
  the `mediaItem` query describe the same item, and two copies of this mapping
  would drift into reporting different availability for it.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Media
  alias Mydia.Media.MediaItem

  @doc """
  The preloads every item must carry before `item_map/1` runs.

  Mandatory, not an optimisation: `get_media_status/1` reads an item's downloads,
  its media files, and each episode's media files, so an item that is not
  preloaded raises rather than reporting a wrong status.

  Mirrors `lib/mydia_web/live/media_live/index.ex`'s shape, including
  `MediaFile.versions/0` -- the one place trashed files and extras are excluded --
  so this API's `status` and `hasFile` agree with the UI badge.
  """
  @spec preloads() :: keyword()
  def preloads do
    [
      :quality_profile,
      :downloads,
      media_files: MediaFile.versions(),
      episodes: [media_files: MediaFile.versions(), downloads: []]
    ]
  end

  @doc "Maps a preloaded media item onto the GraphQL shape."
  @spec item_map(MediaItem.t()) :: map()
  def item_map(%MediaItem{} = item) do
    %{
      id: item.id,
      type: String.to_existing_atom(item.type),
      title: item.title,
      year: item.year,
      tmdb_id: item.tmdb_id,
      tvdb_id: item.tvdb_id,
      imdb_id: item.imdb_id,
      monitored: item.monitored,
      quality_profile: item.quality_profile,
      status: Media.get_media_status(item),
      added_at: item.inserted_at,
      updated_at: item.updated_at,
      episodes: Map.get(item, :episodes) || []
    }
  end

  @doc "Maps a preloaded episode onto the GraphQL shape."
  @spec episode_map(Mydia.Media.Episode.t()) :: map()
  def episode_map(episode) do
    %{
      id: episode.id,
      season_number: episode.season_number,
      episode_number: episode.episode_number,
      title: episode.title,
      air_date: episode.air_date,
      monitored: episode.monitored,
      # many_to_many, so a multi-episode file counts for each episode it covers.
      # The preload is what makes this a list; an unloaded association is a
      # struct, and `!= []` on it would report every episode as having a file.
      has_file: episode.media_files != []
    }
  end
end
