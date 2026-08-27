defmodule Mydia.Collections do
  @moduledoc """
  The Collections context handles user collections of media items.

  Collections can be:
  - **Manual**: User-curated lists where items are explicitly added and reordered
  - **Smart**: Rule-based collections that auto-populate based on filter criteria

  ## Visibility

  - `private`: Only visible to the owner (default)
  - `shared`: Visible to all users (admin only can create)

  ## System Collections

  Each user has a special "Favorites" collection created automatically.
  System collections cannot be deleted or renamed.
  """

  use Mydia.QueryHelpers.Filterable,
    function_name: :apply_collection_filters,
    filters: [
      type: {:eq, values: ["manual", "smart"]},
      visibility: {:eq, values: ["private", "shared"]}
    ]

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  alias Mydia.Repo
  alias Mydia.Collections.{Collection, CollectionItem, SmartRules}
  alias Mydia.Media.MediaItem
  alias Mydia.Accounts.User

  ## Collections

  @doc """
  Returns the list of collections accessible to a user.

  ## Options
    - `:type` - Filter by type ("manual" or "smart")
    - `:visibility` - Filter by visibility ("private" or "shared")
    - `:include_shared` - Include shared collections from other users (default: true)
    - `:preload` - List of associations to preload
  """
  @spec list_collections(User.t(), keyword()) :: [Collection.t()]
  def list_collections(%User{} = user, opts \\ []) do
    include_shared = Keyword.get(opts, :include_shared, true)

    query =
      if include_shared do
        # User's own collections + shared collections from anyone
        from(c in Collection,
          where: c.user_id == ^user.id or c.visibility == "shared",
          order_by: [asc: c.position, asc: c.name]
        )
      else
        # Only user's own collections
        from(c in Collection,
          where: c.user_id == ^user.id,
          order_by: [asc: c.position, asc: c.name]
        )
      end

    query
    |> apply_collection_filters(opts)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Gets a single collection accessible to the user.

  Returns the collection if:
  - User owns it, OR
  - Collection is shared

  Raises `Ecto.NoResultsError` if collection doesn't exist or isn't accessible.
  """
  @spec get_collection!(User.t(), binary(), keyword()) :: Collection.t()
  def get_collection!(%User{} = user, id, opts \\ []) do
    Collection
    |> where([c], c.id == ^id)
    |> where([c], c.user_id == ^user.id or c.visibility == "shared")
    |> maybe_preload(opts[:preload])
    |> Repo.one!()
  end

  @doc """
  Gets a collection by ID, returning nil if not found.
  Only returns collections accessible to the user.
  """
  @spec get_collection(User.t(), binary(), keyword()) :: Collection.t() | nil
  def get_collection(%User{} = user, id, opts \\ []) do
    Collection
    |> where([c], c.id == ^id)
    |> where([c], c.user_id == ^user.id or c.visibility == "shared")
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Gets a collection by ID without user access checks.

  This is intended for internal system use only (e.g., import list auto-add).
  For user-facing code, use `get_collection/2` or `get_collection!/2` instead.
  """
  @spec get_collection_by_id(binary(), keyword()) :: Collection.t() | nil
  def get_collection_by_id(id, opts \\ []) do
    Collection
    |> maybe_preload(opts[:preload])
    |> Repo.get(id)
  end

  @doc """
  Creates a collection for a user.

  Regular users can only create private collections.
  Admins can create shared collections.

  ## Examples

      iex> create_collection(user, %{name: "My Collection", type: "manual"})
      {:ok, %Collection{}}

      iex> create_collection(regular_user, %{name: "Test", visibility: "shared"})
      {:error, :unauthorized}
  """
  @spec create_collection(User.t(), map()) ::
          {:ok, Collection.t()} | {:error, Ecto.Changeset.t() | :unauthorized}
  def create_collection(%User{} = user, attrs) do
    visibility = Map.get(attrs, :visibility, Map.get(attrs, "visibility", "private"))

    # Only admins can create shared collections
    if visibility == "shared" and user.role != "admin" do
      {:error, :unauthorized}
    else
      %Collection{user_id: user.id}
      |> Collection.changeset(attrs)
      |> Repo.insert()
    end
  end

  @doc """
  Updates a collection.

  Only the owner can update a collection. System collections cannot be updated.
  Regular users cannot change visibility to "shared".
  """
  @spec update_collection(User.t(), Collection.t(), map()) ::
          {:ok, Collection.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :system_collection}
  def update_collection(%User{} = user, %Collection{} = collection, attrs) do
    cond do
      collection.user_id != user.id ->
        {:error, :unauthorized}

      collection.is_system ->
        {:error, :system_collection}

      true ->
        # Prevent non-admins from setting visibility to shared
        visibility = Map.get(attrs, :visibility, Map.get(attrs, "visibility"))

        if visibility == "shared" and user.role != "admin" do
          {:error, :unauthorized}
        else
          collection
          |> Collection.changeset(attrs)
          |> Repo.update()
        end
    end
  end

  @doc """
  Deletes a collection.

  Only the owner can delete. System collections cannot be deleted.
  """
  @spec delete_collection(User.t(), Collection.t()) ::
          {:ok, Collection.t()}
          | {:error, Ecto.Changeset.t() | :unauthorized | :system_collection}
  def delete_collection(%User{} = user, %Collection{} = collection) do
    cond do
      collection.user_id != user.id ->
        {:error, :unauthorized}

      collection.is_system ->
        {:error, :system_collection}

      true ->
        Repo.delete(collection)
    end
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking collection changes.
  """
  @spec change_collection(Collection.t(), map()) :: Ecto.Changeset.t()
  def change_collection(%Collection{} = collection, attrs \\ %{}) do
    Collection.changeset(collection, attrs)
  end

  ## Favorites (System Collection)

  @doc """
  Gets or creates the Favorites collection for a user.

  Each user has exactly one Favorites collection which is a system collection.
  """
  @spec get_or_create_favorites(User.t()) :: {:ok, Collection.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create_favorites(%User{} = user) do
    case Repo.get_by(Collection, user_id: user.id, is_system: true, name: "Favorites") do
      nil ->
        %Collection{user_id: user.id}
        |> Collection.system_changeset(%{name: "Favorites", type: "manual"})
        |> Repo.insert()

      favorites ->
        {:ok, favorites}
    end
  end

  @doc """
  Checks if a media item is in the user's Favorites collection.
  """
  @spec is_favorite?(User.t(), MediaItem.t() | binary()) :: boolean()
  def is_favorite?(%User{} = user, %MediaItem{} = media_item) do
    is_favorite?(user, media_item.id)
  end

  def is_favorite?(%User{} = user, media_item_id) when is_binary(media_item_id) do
    case get_or_create_favorites(user) do
      {:ok, favorites} ->
        Repo.exists?(
          from(ci in CollectionItem,
            where: ci.collection_id == ^favorites.id and ci.media_item_id == ^media_item_id
          )
        )

      {:error, _} ->
        false
    end
  end

  @doc """
  Toggles a media item's presence in the user's Favorites collection.

  Returns `{:ok, :added}` or `{:ok, :removed}`.
  """
  @spec toggle_favorite(User.t(), binary()) :: {:ok, :added | :removed} | {:error, term()}
  def toggle_favorite(%User{} = user, media_item_id) do
    with {:ok, favorites} <- get_or_create_favorites(user) do
      case Repo.get_by(CollectionItem,
             collection_id: favorites.id,
             media_item_id: media_item_id
           ) do
        nil ->
          case add_item(favorites, media_item_id) do
            {:ok, _item} -> {:ok, :added}
            {:error, reason} -> {:error, reason}
          end

        item ->
          case Repo.delete(item) do
            {:ok, _} -> {:ok, :removed}
            {:error, changeset} -> {:error, changeset}
          end
      end
    end
  end

  ## Collection Items

  @doc """
  Lists items in a collection.

  For manual collections, returns items ordered by position.
  For smart collections, returns items matching the smart rules.

  ## Options
    - `:preload` - List of associations to preload on media_items
    - `:limit` - Maximum number of items to return
    - `:offset` - Number of items to skip
  """
  @spec list_collection_items(Collection.t(), keyword()) :: [MediaItem.t()]
  def list_collection_items(collection, opts \\ [])

  def list_collection_items(%Collection{type: "manual"} = collection, opts) do
    query =
      from(ci in CollectionItem,
        where: ci.collection_id == ^collection.id,
        order_by: [asc: ci.position],
        preload: [:media_item]
      )

    query
    |> apply_pagination(opts)
    |> Repo.all()
    |> Enum.map(& &1.media_item)
    |> maybe_preload_items(opts[:preload])
  end

  def list_collection_items(%Collection{type: "smart"} = collection, opts) do
    SmartRules.execute_query!(collection.smart_rules || "{}", opts)
  end

  @doc """
  Returns the number of items in a collection.
  """
  @spec item_count(Collection.t()) :: non_neg_integer()
  def item_count(%Collection{type: "manual"} = collection) do
    Repo.aggregate(
      from(ci in CollectionItem, where: ci.collection_id == ^collection.id),
      :count
    )
  end

  def item_count(%Collection{type: "smart"} = collection) do
    SmartRules.execute_count(collection.smart_rules || "{}")
  end

  @doc """
  Returns up to `count` poster paths from a collection's items.

  Useful for displaying a poster collage on collection cards.
  Returns a list of TMDB poster paths (strings) from the first N items.
  """
  @spec poster_paths(Collection.t(), non_neg_integer()) :: [binary()]
  def poster_paths(%Collection{} = collection, count \\ 4) do
    items = list_collection_items(collection, limit: count)

    items
    |> Enum.map(fn item ->
      case item.metadata do
        %{poster_path: path} when is_binary(path) -> path
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Validates smart rules for a collection.
  Delegates to `SmartRules.validate/1`.
  """
  @spec validate_smart_rules(binary() | map()) :: {:ok, map()} | {:error, [binary()]}
  def validate_smart_rules(rules) do
    SmartRules.validate(rules)
  end

  @doc """
  Previews items that would be included in a smart collection with the given rules.
  Useful for showing users what a smart collection will contain before saving.
  """
  @spec preview_smart_rules(binary() | map(), non_neg_integer()) :: [MediaItem.t()]
  def preview_smart_rules(rules, limit \\ 10) do
    SmartRules.preview(rules, limit)
  end

  @doc """
  Adds an item to a manual collection.

  The item is added at the end of the collection (highest position + 1).
  Returns {:error, :smart_collection} if called on a smart collection.
  """
  @spec add_item(Collection.t(), binary()) ::
          {:ok, CollectionItem.t()} | {:error, Ecto.Changeset.t() | :smart_collection}
  def add_item(%Collection{type: "smart"}, _media_item_id) do
    {:error, :smart_collection}
  end

  def add_item(%Collection{type: "manual"} = collection, media_item_id) do
    # Get the next position
    max_position =
      Repo.one(
        from(ci in CollectionItem,
          where: ci.collection_id == ^collection.id,
          select: max(ci.position)
        )
      ) || -1

    %CollectionItem{
      collection_id: collection.id,
      media_item_id: media_item_id,
      position: max_position + 1
    }
    |> CollectionItem.changeset(%{})
    |> Repo.insert()
  end

  @doc """
  Adds multiple items to a manual collection.

  Items are added at the end in the order provided.
  Returns `{:ok, count}` where count is the number of items added, or
  `{:error, :not_found}` if any id does not reference an existing media item.
  """
  @spec add_items(Collection.t(), [binary()]) ::
          {:ok, non_neg_integer()} | {:error, :smart_collection | :not_found}
  def add_items(%Collection{type: "smart"}, _media_item_ids) do
    {:error, :smart_collection}
  end

  def add_items(%Collection{type: "manual"} = collection, media_item_ids)
      when is_list(media_item_ids) do
    if all_media_items_exist?(media_item_ids) do
      do_add_items(collection, media_item_ids)
    else
      {:error, :not_found}
    end
  end

  # Repo.insert_all/3 takes no changeset, so Mydia.Repo.ForeignKeyGuard cannot
  # turn a foreign key violation below into a changeset error: on SQLite it
  # raises. Check the ids up front instead. `on_conflict: :nothing` tolerates a
  # duplicate, but a reference to something that does not exist is a different
  # thing and should not be dropped silently.
  defp all_media_items_exist?(media_item_ids) do
    ids = Enum.uniq(media_item_ids)
    found = Repo.all(from(m in MediaItem, where: m.id in ^ids, select: m.id)) |> MapSet.new()

    Enum.all?(ids, &MapSet.member?(found, &1))
  rescue
    # PostgreSQL raises while binding a non-UUID-shaped id. It certainly does
    # not exist.
    Ecto.Query.CastError -> false
  end

  defp do_add_items(collection, media_item_ids) do
    max_position =
      Repo.one(
        from(ci in CollectionItem,
          where: ci.collection_id == ^collection.id,
          select: max(ci.position)
        )
      ) || -1

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    items =
      media_item_ids
      |> Enum.with_index(max_position + 1)
      |> Enum.map(fn {media_item_id, position} ->
        %{
          id: Ecto.UUID.generate(),
          collection_id: collection.id,
          media_item_id: media_item_id,
          position: position,
          inserted_at: now
        }
      end)

    {count, _} =
      Repo.insert_all(CollectionItem, items, on_conflict: :nothing)

    {:ok, count}
  end

  @doc """
  Removes an item from a manual collection.
  """
  @spec remove_item(Collection.t(), binary()) ::
          {:ok, CollectionItem.t()}
          | {:error, Ecto.Changeset.t() | :smart_collection | :not_found}
  def remove_item(%Collection{type: "smart"}, _media_item_id) do
    {:error, :smart_collection}
  end

  def remove_item(%Collection{type: "manual"} = collection, media_item_id) do
    case Repo.get_by(CollectionItem,
           collection_id: collection.id,
           media_item_id: media_item_id
         ) do
      nil ->
        {:error, :not_found}

      item ->
        Repo.delete(item)
    end
  end

  @doc """
  Reorders items in a manual collection.

  Takes a list of media_item_ids in the desired order.
  Updates the position of each item to match its index in the list.
  """
  @spec reorder_items(Collection.t(), [binary()]) :: {:ok, :ok} | {:error, :smart_collection}
  def reorder_items(%Collection{type: "smart"}, _item_ids) do
    {:error, :smart_collection}
  end

  def reorder_items(%Collection{type: "manual"} = collection, item_ids)
      when is_list(item_ids) do
    Repo.transaction(fn ->
      item_ids
      |> Enum.with_index()
      |> Enum.each(fn {media_item_id, position} ->
        from(ci in CollectionItem,
          where: ci.collection_id == ^collection.id and ci.media_item_id == ^media_item_id
        )
        |> Repo.update_all(set: [position: position])
      end)

      :ok
    end)
  end

  @doc """
  Returns playable items from a collection with their best media files.

  This is used for "Play All" functionality - returns a list of maps with:
  - :type - "movie" or "episode"
  - :id - media item or episode ID
  - :file_id - the best quality file ID
  - :title - display title

  For movies: returns the movie with its best file.
  For TV shows: returns all episodes with files, ordered by season/episode.

  ## Options
    - `:limit` - Maximum number of items to return (default: 100)
  """
  @spec get_playable_items(Collection.t(), keyword()) :: [map()]
  def get_playable_items(%Collection{} = collection, opts \\ []) do
    limit = Keyword.get(opts, :limit, 100)

    # Get collection items
    items = list_collection_items(collection, limit: limit)

    # For each item, get playable content
    items
    |> Enum.flat_map(&get_playable_content/1)
    |> Enum.reject(&is_nil/1)
  end

  defp get_playable_content(%MediaItem{type: "movie"} = item) do
    # Preload media files if not already loaded
    item = Repo.preload(item, :media_files)

    case get_best_file(item.media_files) do
      nil ->
        []

      file ->
        [
          %{
            type: "movie",
            id: item.id,
            file_id: file.id,
            title: item.title
          }
        ]
    end
  end

  defp get_playable_content(%MediaItem{type: "tv_show"} = item) do
    # Preload episodes with their media files
    item = Repo.preload(item, episodes: :media_files)

    item.episodes
    |> Enum.sort_by(&{&1.season_number, &1.episode_number})
    |> Enum.flat_map(fn episode ->
      case get_best_file(episode.media_files) do
        nil ->
          []

        file ->
          title =
            "#{item.title} - S#{String.pad_leading(to_string(episode.season_number), 2, "0")}E#{String.pad_leading(to_string(episode.episode_number), 2, "0")}"

          title = if episode.title, do: "#{title} - #{episode.title}", else: title

          [
            %{
              type: "episode",
              id: episode.id,
              file_id: file.id,
              title: title
            }
          ]
      end
    end)
  end

  defp get_playable_content(_item), do: []

  defp get_best_file(nil), do: nil
  defp get_best_file([]), do: nil

  defp get_best_file(files) do
    files
    |> Enum.sort_by(&resolution_priority(&1.resolution), :desc)
    |> List.first()
  end

  defp resolution_priority(nil), do: 0
  defp resolution_priority("480p"), do: 1
  defp resolution_priority("720p"), do: 2
  defp resolution_priority("1080p"), do: 3
  defp resolution_priority("2160p"), do: 4
  defp resolution_priority("4K"), do: 4
  defp resolution_priority(_), do: 0

  @doc """
  Returns all collections that contain a specific media item.
  Only returns collections accessible to the user.
  """
  @spec collections_for_item(User.t(), binary()) :: [Collection.t()]
  def collections_for_item(%User{} = user, media_item_id) do
    # Get IDs of manual collections containing this item
    manual_collection_ids =
      from(ci in CollectionItem,
        where: ci.media_item_id == ^media_item_id,
        select: ci.collection_id
      )
      |> Repo.all()

    # Return collections that:
    # 1. Are manual and contain the item, AND
    # 2. Are accessible to the user (owned or shared)
    from(c in Collection,
      where: c.id in ^manual_collection_ids,
      where: c.user_id == ^user.id or c.visibility == "shared",
      order_by: [asc: c.name]
    )
    |> Repo.all()
  end

  ## Private Helpers

  defp apply_pagination(query, opts) do
    query
    |> apply_limit(opts[:limit])
    |> apply_offset(opts[:offset])
  end

  defp apply_limit(query, nil), do: query
  defp apply_limit(query, limit) when is_integer(limit), do: limit(query, ^limit)

  defp apply_offset(query, nil), do: query
  defp apply_offset(query, offset) when is_integer(offset), do: offset(query, ^offset)

  defp maybe_preload_items(items, nil), do: items
  defp maybe_preload_items(items, []), do: items
  defp maybe_preload_items(items, preloads), do: Repo.preload(items, preloads)
end
