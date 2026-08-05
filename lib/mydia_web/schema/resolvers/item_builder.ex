defmodule MydiaWeb.Schema.Resolvers.ItemBuilder do
  @moduledoc """
  Builds the `:recently_added_item` GraphQL payload from a media item.

  Both the discovery and collection resolvers render this object. They used to
  carry byte-for-byte copies of this function, which meant two definitions of
  "added" that could drift apart. There is one here now.
  """

  alias Mydia.Metadata.Access, as: MetadataAccess
  alias Mydia.Metadata.ImageUrl

  @doc """
  Builds the payload.

  Options:

    * `:added_at` - overrides the timestamp. Defaults to the item's
      `inserted_at`, which is only correct for callers that have no better
      answer.
    * `:new_episode_count` - episodes whose first file landed inside the
      caller's window. Nil for movies and for unwindowed views.
    * `:latest_episode` - an `%Mydia.Media.Episode{}` whose numbers are
      flattened onto the payload, or nil.
  """
  @spec recently_added_item(struct(), keyword()) :: map()
  def recently_added_item(media_item, opts \\ []) do
    latest_episode = Keyword.get(opts, :latest_episode)

    %{
      id: media_item.id,
      type: String.to_existing_atom(media_item.type),
      title: media_item.title,
      year: media_item.year,
      artwork: artwork(media_item),
      added_at: Keyword.get(opts, :added_at) || media_item.inserted_at,
      new_episode_count: Keyword.get(opts, :new_episode_count),
      latest_season_number: latest_episode && latest_episode.season_number,
      latest_episode_number: latest_episode && latest_episode.episode_number
    }
  end

  @doc """
  Builds the artwork sub-object from an item's metadata.
  """
  @spec artwork(struct()) :: map() | nil
  def artwork(%{metadata: nil}), do: nil

  def artwork(%{metadata: metadata}) do
    %{
      poster_url: metadata |> MetadataAccess.get(:poster_path) |> ImageUrl.poster_url(),
      backdrop_url: metadata |> MetadataAccess.get(:backdrop_path) |> ImageUrl.backdrop_url(),
      thumbnail_url: nil
    }
  end

  def artwork(_), do: nil
end
