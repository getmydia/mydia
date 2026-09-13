defmodule MydiaWeb.LibrarySchema.Resolvers.Library do
  @moduledoc """
  Resolves `mediaItem`.

  Every item is hydrated with the media index's preload shape. `get_media_status/1`
  reads an item's downloads, its media files, and each episode's media files, so
  an item that is not preloaded raises on access rather than reporting a wrong
  status.

  `updatedAt` is the item's aggregate revision timestamp from the
  `media_item_revisions` marker, so a single item read agrees with the
  `mediaItemChanges` feed.
  """

  alias Mydia.LibraryApi.RevisionFeed
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias MydiaWeb.LibrarySchema.MediaItemView

  @spec media_item(any(), map(), Absinthe.Resolution.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def media_item(_parent, args, _info) do
    with {:ok, opts} <- identify(args) do
      case fetch_one(opts) do
        nil ->
          {:ok, nil}

        item ->
          with {:ok, changed_at} <- RevisionFeed.live_changed_at(item.id) do
            {:ok, changed_at && MediaItemView.item_map(item, changed_at)}
          end
      end
    end
  end

  # Exactly one identifier, because two of them could name different items and
  # silently preferring one is worse than refusing.
  defp identify(args) do
    provided =
      args
      |> Map.take([:id, :tmdb_id, :tvdb_id, :imdb_id])
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)

    case provided do
      [{:id, id}] ->
        case Ecto.UUID.cast(id) do
          {:ok, id} ->
            {:ok, {:id, id}}

          :error ->
            {:error, %{message: "Invalid media item id", extensions: %{code: "INVALID_INPUT"}}}
        end

      [{key, value}] when key in [:tmdb_id, :tvdb_id, :imdb_id] ->
        type = Map.get(args, :type)

        if key == :tmdb_id and is_nil(type) do
          {:error,
           %{
             message: "tmdbId requires type: TMDB numbers movies and TV shows separately",
             extensions: %{code: "INVALID_INPUT"}
           }}
        else
          {:ok, {:external, key, value, type}}
        end

      [] ->
        {:error,
         %{
           message: "Provide one of id, tmdbId, tvdbId or imdbId",
           extensions: %{code: "INVALID_INPUT"}
         }}

      _many ->
        {:error,
         %{message: "Provide exactly one identifier", extensions: %{code: "INVALID_INPUT"}}}
    end
  end

  defp fetch_one({:id, id}) do
    case Media.list_media_items(ids: [id], preload: MediaItemView.preloads()) do
      [item | _] -> item
      [] -> nil
    end
  end

  defp fetch_one({:external, key, value, type}) do
    # find_by_external_ids/2 takes short keys (%{tmdb:, tvdb:, imdb:}), not the
    # GraphQL argument names. Passing :tmdb_id here matches nothing and returns
    # nil for every lookup.
    ids = %{external_key(key) => value}

    case Media.find_by_external_ids(ids, type: type && to_string(type)) do
      nil -> nil
      %MediaItem{id: id} -> fetch_one({:id, id})
    end
  end

  defp external_key(:tmdb_id), do: :tmdb
  defp external_key(:tvdb_id), do: :tvdb
  defp external_key(:imdb_id), do: :imdb

  # The parent here is the map `MediaItemView.item_map/2` produced, not the
  # %MediaItem{} it came from, because Absinthe resolves a field against whatever
  # its parent field returned. The episodes are already loaded by the preload, so
  # the season filter is in memory rather than another query.
  @doc false
  def episodes(%{episodes: episodes}, args, _info) do
    filtered =
      case Map.get(args, :season) do
        nil -> episodes
        season -> Enum.filter(episodes, &(&1.season_number == season))
      end

    {:ok, Enum.map(filtered, &MediaItemView.episode_map/1)}
  end
end
