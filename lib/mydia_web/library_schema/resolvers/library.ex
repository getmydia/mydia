defmodule MydiaWeb.LibrarySchema.Resolvers.Library do
  @moduledoc """
  Resolves `mediaItem` and `mediaItems`.

  Every item is hydrated with the media index's preload shape. `get_media_status/1`
  reads an item's downloads, its media files, and each episode's media files, so
  an item that is not preloaded raises on access rather than reporting a wrong
  status.
  """

  alias Mydia.LibraryApi.Cursor
  alias Mydia.Media
  alias Mydia.Media.MediaItem
  alias MydiaWeb.LibrarySchema.MediaItemView

  @default_first 50
  @max_first 200

  @spec media_item(any(), map(), Absinthe.Resolution.t()) ::
          {:ok, map() | nil} | {:error, term()}
  def media_item(_parent, args, _info) do
    with {:ok, opts} <- identify(args) do
      item = fetch_one(opts)

      {:ok, item && MediaItemView.item_map(item)}
    end
  end

  @spec media_items(any(), map(), Absinthe.Resolution.t()) :: {:ok, map()} | {:error, term()}
  def media_items(_parent, args, _info) do
    with {:ok, first} <- page_size(Map.get(args, :first)),
         {:ok, after_cursor} <- decode_cursor(Map.get(args, :after)) do
      # One extra row decides hasNextPage without a second count query.
      page_opts =
        [limit: first + 1]
        |> maybe_put(:after, after_cursor)
        |> maybe_put(:updated_since, Map.get(args, :updated_since))

      rows = Media.list_items_page(page_opts)
      {page, _rest} = Enum.split(rows, first)
      ids = Enum.map(page, & &1.id)

      hydrated_by_id =
        ids
        |> case do
          [] -> []
          ids -> Media.list_media_items(ids: ids, preload: MediaItemView.preloads())
        end
        |> Map.new(&{&1.id, &1})

      # Keep `page` as the cursor source: hydration can see a newer updated_at,
      # or miss a row deleted after the keyset query. A cursor from either state
      # could skip rows or crash pagination on a concurrent change.
      {:ok, connection(page, hydrated_by_id, length(rows) > first)}
    end
  end

  # `first` reaches Ecto's `limit`, where 0 and negative values do not mean
  # "no rows": they are invalid or surprising, so they are refused rather than
  # clamped. A client that asks for 0 has a bug worth surfacing.
  defp page_size(nil), do: {:ok, @default_first}

  defp page_size(first) when is_integer(first) and first >= 1 and first <= @max_first,
    do: {:ok, first}

  defp page_size(first) when is_integer(first) do
    {:error,
     %{
       message: "first must be between 1 and #{@max_first}, got #{first}",
       extensions: %{code: "INVALID_INPUT"}
     }}
  end

  defp page_size(_first) do
    {:error, %{message: "first must be an integer", extensions: %{code: "INVALID_INPUT"}}}
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

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) do
    case Cursor.decode(cursor) do
      {:ok, value} -> {:ok, value}
      :error -> {:error, %{message: "Invalid cursor", extensions: %{code: "INVALID_INPUT"}}}
    end
  end

  defp connection([], _hydrated_by_id, _has_next),
    do: %{edges: [], page_info: %{has_next_page: false, end_cursor: nil}}

  defp connection(page, hydrated_by_id, has_next) do
    edges =
      for boundary <- page,
          {:ok, item} <- [Map.fetch(hydrated_by_id, boundary.id)] do
        %{
          node: MediaItemView.item_map(item),
          cursor: Cursor.encode(boundary.updated_at, boundary.id)
        }
      end

    last = List.last(page)

    %{
      edges: edges,
      page_info: %{
        has_next_page: has_next,
        end_cursor: Cursor.encode(last.updated_at, last.id)
      }
    }
  end

  # The parent here is the map `MediaItemView.item_map/1` produced, not the
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

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)
end
