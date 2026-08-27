defmodule Mydia.ImportLists do
  @moduledoc """
  Context for managing import lists.

  Import lists allow users to automatically sync media from external sources like
  TMDB trending/popular lists. This context provides functions for managing lists,
  their items, and syncing operations.
  """

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  alias Mydia.Accounts.Scope
  alias Mydia.Repo

  alias Mydia.ImportLists.{ImportList, ImportListItem}

  ## Preset Definitions

  @presets [
    %{
      id: :tmdb_trending_movies,
      name: "TMDB Trending Movies",
      type: "tmdb_trending",
      media_type: "movie",
      description: "Movies trending on TMDB this week"
    },
    %{
      id: :tmdb_popular_movies,
      name: "TMDB Popular Movies",
      type: "tmdb_popular",
      media_type: "movie",
      description: "Most popular movies on TMDB"
    },
    %{
      id: :tmdb_upcoming_movies,
      name: "TMDB Upcoming Movies",
      type: "tmdb_upcoming",
      media_type: "movie",
      description: "Upcoming movie releases"
    },
    %{
      id: :tmdb_now_playing_movies,
      name: "TMDB Now Playing",
      type: "tmdb_now_playing",
      media_type: "movie",
      description: "Movies currently in theaters"
    },
    %{
      id: :tmdb_trending_tv,
      name: "TMDB Trending TV Shows",
      type: "tmdb_trending",
      media_type: "tv_show",
      description: "TV shows trending on TMDB this week"
    },
    %{
      id: :tmdb_popular_tv,
      name: "TMDB Popular TV Shows",
      type: "tmdb_popular",
      media_type: "tv_show",
      description: "Most popular TV shows on TMDB"
    },
    %{
      id: :tmdb_on_the_air,
      name: "TMDB On The Air",
      type: "tmdb_on_the_air",
      media_type: "tv_show",
      description: "TV shows currently airing"
    },
    %{
      id: :tmdb_airing_today,
      name: "TMDB Airing Today",
      type: "tmdb_airing_today",
      media_type: "tv_show",
      description: "TV shows airing today"
    }
  ]

  ## List Management

  @doc """
  Returns the list of import lists.

  ## Options
    - `:preload` - List of associations to preload
    - `:enabled` - Filter by enabled status
    - `:media_type` - Filter by media type (:movie, :tv_show)
  """
  def list_import_lists(opts \\ []) do
    ImportList
    |> apply_filters(opts)
    |> maybe_preload(opts[:preload])
    |> order_by([l], desc: l.enabled, asc: l.name)
    |> Repo.all()
  end

  @doc """
  Returns the list of import lists filtered by media type.
  """
  def list_import_lists_by_type(media_type, opts \\ []) when is_binary(media_type) do
    list_import_lists(Keyword.put(opts, :media_type, media_type))
  end

  @doc """
  Gets a single import list.

  Raises `Ecto.NoResultsError` if the import list does not exist.
  """
  def get_import_list!(id, opts \\ []) do
    ImportList
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets an import list by type and media type.
  """
  def get_import_list_by_type(type, media_type) do
    ImportList
    |> where([l], l.type == ^type and l.media_type == ^media_type)
    |> Repo.one()
  end

  @doc """
  Creates an import list.
  """
  def create_import_list(attrs \\ %{}) do
    %ImportList{}
    |> ImportList.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an import list.
  """
  def update_import_list(%ImportList{} = import_list, attrs) do
    import_list
    |> ImportList.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Deletes an import list and all its items.
  """
  def delete_import_list(%ImportList{} = import_list) do
    Repo.delete(import_list)
  end

  @doc """
  Toggles an import list's enabled status.
  """
  def toggle_import_list(%ImportList{} = import_list) do
    update_import_list(import_list, %{enabled: not import_list.enabled})
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking import list changes.
  """
  def change_import_list(%ImportList{} = import_list, attrs \\ %{}) do
    ImportList.changeset(import_list, attrs)
  end

  ## List Items

  @doc """
  Returns the list of items for an import list.

  ## Options
    - `:preload` - List of associations to preload
    - `:status` - Filter by status
    - `:limit` - Limit number of results
    - `:offset` - Offset for pagination
  """
  def list_import_list_items(%ImportList{} = import_list, opts \\ []) do
    list_import_list_items_by_id(import_list.id, opts)
  end

  def list_import_list_items_by_id(import_list_id, opts \\ []) do
    status = Keyword.get(opts, :status)
    limit_val = Keyword.get(opts, :limit)
    offset_val = Keyword.get(opts, :offset, 0)

    # Build query with left join to compute in_library dynamically
    query =
      from(i in ImportListItem,
        left_join: m in assoc(i, :media_item),
        where: i.import_list_id == ^import_list_id,
        # in_library is true if the media_item still exists
        select: %{i | in_library: not is_nil(m.id)},
        order_by: [desc: i.discovered_at]
      )
      |> maybe_filter_status_with_library(status)
      |> maybe_preload(opts[:preload])

    query =
      if limit_val do
        query
        |> limit(^limit_val)
        |> offset(^offset_val)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Returns the count of items for an import list by status.
  """
  def count_import_list_items(%ImportList{} = import_list, status \\ nil) do
    count_import_list_items_by_id(import_list.id, status)
  end

  def count_import_list_items_by_id(import_list_id, status \\ nil) do
    from(i in ImportListItem,
      left_join: m in assoc(i, :media_item),
      where: i.import_list_id == ^import_list_id
    )
    |> maybe_filter_status_with_library(status)
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns pending items for an import list.
  """
  def get_pending_items(%ImportList{} = import_list, opts \\ []) do
    list_import_list_items(import_list, Keyword.put(opts, :status, "pending"))
  end

  @doc """
  Gets a single import list item.
  """
  def get_import_list_item!(id, opts \\ []) do
    ImportListItem
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Creates an import list item.
  """
  def create_import_list_item(attrs \\ %{}) do
    %ImportListItem{}
    |> ImportListItem.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Creates an import list item, or updates it if it already exists.

  Uses the unique constraint on (import_list_id, tmdb_id) to detect conflicts.
  Returns {:ok, item} where item is either newly created or the updated existing item.
  """
  def upsert_import_list_item(attrs) do
    import_list_id = attrs[:import_list_id] || attrs["import_list_id"]
    tmdb_id = attrs[:tmdb_id] || attrs["tmdb_id"]

    # Try to find existing item first
    existing =
      ImportListItem
      |> where([i], i.import_list_id == ^import_list_id and i.tmdb_id == ^tmdb_id)
      |> Repo.one()

    case existing do
      nil ->
        # Create new item
        create_import_list_item(attrs)

      item ->
        # Update existing item (only update cached display fields)
        item
        |> ImportListItem.changeset(%{
          title: attrs[:title] || attrs["title"],
          year: attrs[:year] || attrs["year"],
          poster_path: attrs[:poster_path] || attrs["poster_path"]
        })
        |> Repo.update()
    end
  end

  @doc """
  Marks an import list item as added.
  """
  def mark_item_added(%ImportListItem{} = item, media_item_id) do
    item
    |> ImportListItem.changeset(%{
      status: "added",
      media_item_id: media_item_id,
      skip_reason: nil
    })
    |> Repo.update()
  end

  @doc """
  Marks an import list item as skipped.
  """
  def mark_item_skipped(%ImportListItem{} = item, reason) do
    item
    |> ImportListItem.changeset(%{
      status: "skipped",
      skip_reason: reason
    })
    |> Repo.update()
  end

  @doc """
  Marks an import list item as failed.
  """
  def mark_item_failed(%ImportListItem{} = item, reason) do
    item
    |> ImportListItem.changeset(%{
      status: "failed",
      skip_reason: reason
    })
    |> Repo.update()
  end

  @doc """
  Resets an import list item to pending status.
  """
  def reset_item(%ImportListItem{} = item) do
    item
    |> ImportListItem.changeset(%{
      status: "pending",
      skip_reason: nil,
      media_item_id: nil
    })
    |> Repo.update()
  end

  @doc """
  Deletes an import list item.
  """
  def delete_import_list_item(%ImportListItem{} = item) do
    Repo.delete(item)
  end

  ## Preset Management

  @doc """
  Returns all available preset list definitions.
  """
  def available_preset_lists do
    @presets
  end

  @doc """
  Returns presets filtered by media type.
  """
  def available_preset_lists_by_type(media_type) do
    Enum.filter(@presets, &(&1.media_type == media_type))
  end

  @doc """
  Checks if a preset is already configured.
  """
  def preset_configured?(preset_id) do
    preset = Enum.find(@presets, &(&1.id == preset_id))

    if preset do
      case get_import_list_by_type(preset.type, preset.media_type) do
        nil -> false
        _ -> true
      end
    else
      false
    end
  end

  @doc """
  Creates an import list from a preset.

  ## Options
    - `:sync_interval` - Override default sync interval
    - `:auto_add` - Override default auto_add setting
    - `:quality_profile_id` - Set quality profile
    - `:library_path_id` - Set library path
    - `:monitored` - Override default monitored setting
  """
  def create_from_preset(preset_id, opts \\ []) do
    preset = Enum.find(@presets, &(&1.id == preset_id))

    if preset do
      attrs = %{
        name: preset.name,
        type: preset.type,
        media_type: preset.media_type,
        enabled: true,
        sync_interval: Keyword.get(opts, :sync_interval, 360),
        auto_add: Keyword.get(opts, :auto_add, false),
        monitored: Keyword.get(opts, :monitored, true),
        quality_profile_id: Keyword.get(opts, :quality_profile_id),
        library_path_id: Keyword.get(opts, :library_path_id)
      }

      create_import_list(attrs)
    else
      {:error, :preset_not_found}
    end
  end

  ## Sync Operations

  @doc """
  Updates the last synced timestamp for an import list.
  """
  def mark_sync_success(%ImportList{} = import_list) do
    update_import_list(import_list, %{
      last_synced_at: DateTime.utc_now(),
      sync_error: nil
    })
  end

  @doc """
  Records a sync error for an import list.
  """
  def mark_sync_error(%ImportList{} = import_list, error) do
    error_message =
      case error do
        %{message: message} -> message
        message when is_binary(message) -> message
        _ -> inspect(error)
      end

    update_import_list(import_list, %{sync_error: error_message})
  end

  @doc """
  Checks if an import list is due for sync based on its interval.
  """
  def sync_due?(%ImportList{enabled: false}), do: false

  def sync_due?(%ImportList{last_synced_at: nil}), do: true

  def sync_due?(%ImportList{last_synced_at: last_synced, sync_interval: interval}) do
    now = DateTime.utc_now()
    due_at = DateTime.add(last_synced, interval * 60, :second)
    DateTime.compare(now, due_at) in [:gt, :eq]
  end

  @doc """
  Returns all enabled import lists that are due for sync.
  """
  def list_sync_due_lists do
    list_import_lists(enabled: true)
    |> Enum.filter(&sync_due?/1)
  end

  ## Manual Item Addition

  @doc """
  Manually adds a pending import list item to the library.

  This fetches metadata from TMDB and creates a media item in the library.
  Returns `{:ok, media_item}` on success, or `{:error, reason}` on failure.
  """
  def add_item_to_library(%ImportListItem{} = item, %ImportList{} = import_list) do
    case check_duplicate(item.tmdb_id, import_list.media_type) do
      {:duplicate, media_item} ->
        handle_duplicate_item(item, media_item)

      :not_found ->
        fetch_and_create_media_item(item, import_list)
    end
  end

  defp handle_duplicate_item(item, media_item) do
    mark_item_skipped(item, "Already in library")
    {:ok, _} = mark_item_added(item, media_item.id)
    {:ok, media_item}
  end

  defp fetch_and_create_media_item(item, import_list) do
    config = Mydia.Metadata.default_relay_config()
    media_type = normalize_media_type(import_list.media_type)

    case Mydia.Metadata.fetch_by_id(config, to_string(item.tmdb_id), media_type: media_type) do
      {:ok, metadata} ->
        create_media_from_metadata(item, import_list, metadata)

      {:error, reason} ->
        mark_item_failed(item, "Failed to fetch metadata")
        {:error, reason}
    end
  end

  defp normalize_media_type("movie"), do: :movie
  defp normalize_media_type("tv_show"), do: :tv_show
  defp normalize_media_type(mt), do: mt

  defp create_media_from_metadata(item, import_list, metadata) do
    attrs = %{
      type: import_list.media_type,
      title: metadata.title,
      original_title: metadata.original_title,
      year: metadata.year,
      tmdb_id: item.tmdb_id,
      imdb_id: metadata.imdb_id,
      metadata: metadata,
      monitored: import_list.monitored,
      quality_profile_id: import_list.quality_profile_id
    }

    case Mydia.Media.create_media_item(Scope.system(), attrs) do
      {:ok, media_item} ->
        mark_item_added(item, media_item.id)
        maybe_add_to_target_collection(import_list, media_item)
        {:ok, media_item}

      {:error, changeset} ->
        error_msg = format_changeset_error(changeset)
        mark_item_failed(item, error_msg)
        {:error, error_msg}
    end
  end

  # Adds media item to target collection if configured
  defp maybe_add_to_target_collection(%ImportList{target_collection_id: nil}, _media_item),
    do: :ok

  defp maybe_add_to_target_collection(
         %ImportList{target_collection_id: collection_id},
         media_item
       ) do
    alias Mydia.Collections

    case Collections.get_collection_by_id(collection_id) do
      nil ->
        # Collection was deleted, ignore
        :ok

      collection ->
        # Only add to manual collections
        if collection.type == "manual" do
          Collections.add_item(collection, media_item.id)
        end

        :ok
    end
  end

  @doc """
  Adds all pending items from an import list to the library.

  Returns a map with counts: %{added: n, skipped: n, failed: n}
  """
  def add_all_pending_to_library(%ImportList{} = import_list) do
    import_list
    |> get_pending_items()
    |> Enum.reduce(%{added: 0, skipped: 0, failed: 0}, fn item, acc ->
      update_stats_after_add(acc, add_item_to_library(item, import_list), item.id)
    end)
  end

  defp update_stats_after_add(acc, {:ok, _media_item}, item_id) do
    updated_item = get_import_list_item!(item_id)

    if updated_item.status == "skipped" do
      %{acc | skipped: acc.skipped + 1}
    else
      %{acc | added: acc.added + 1}
    end
  end

  defp update_stats_after_add(acc, {:error, _reason}, _item_id) do
    %{acc | failed: acc.failed + 1}
  end

  defp format_changeset_error(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc_msg ->
        String.replace(acc_msg, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  defp format_changeset_error(_), do: "Unknown error"

  ## Duplicate Detection

  @doc """
  Checks if media with the given TMDB ID exists in the library.

  Returns `{:duplicate, media_item}` if found, `:not_found` otherwise.
  """
  def check_duplicate(tmdb_id, media_type) when is_integer(tmdb_id) do
    alias Mydia.Media.MediaItem

    type =
      case media_type do
        "movie" -> "movie"
        "tv_show" -> "tv_show"
        :movie -> "movie"
        :tv_show -> "tv_show"
        _ -> media_type
      end

    # Check by tmdb_id first
    case Repo.get_by(MediaItem, tmdb_id: tmdb_id, type: type) do
      nil ->
        :not_found

      media_item ->
        {:duplicate, media_item}
    end
  end

  @doc """
  Updates import list items to reflect their library status.

  Checks each pending item against the library and marks duplicates as skipped.
  Returns the count of items updated.
  """
  def mark_existing_items_in_library(%ImportList{} = import_list) do
    pending_items = get_pending_items(import_list)

    updated_count =
      Enum.reduce(pending_items, 0, fn item, count ->
        case check_duplicate(item.tmdb_id, import_list.media_type) do
          {:duplicate, media_item} ->
            {:ok, _} = mark_item_skipped(item, "Already in library")
            # Also link to the existing media item
            item
            |> ImportListItem.changeset(%{media_item_id: media_item.id})
            |> Repo.update()

            count + 1

          :not_found ->
            count
        end
      end)

    {:ok, updated_count}
  end

  ## Private Functions

  defp apply_filters(query, opts) do
    query
    |> maybe_filter_enabled(opts[:enabled])
    |> maybe_filter_media_type(opts[:media_type])
  end

  defp maybe_filter_enabled(query, nil), do: query
  defp maybe_filter_enabled(query, enabled), do: where(query, [l], l.enabled == ^enabled)

  defp maybe_filter_media_type(query, nil), do: query

  defp maybe_filter_media_type(query, media_type),
    do: where(query, [l], l.media_type == ^media_type)

  # Filter by status while considering in_library for "added" and "pending" statuses
  # This is used when we have a left join to media_items
  defp maybe_filter_status_with_library(query, nil), do: query

  # "added" means truly in library (media_item exists)
  defp maybe_filter_status_with_library(query, "added") do
    where(query, [i, m], i.status == "added" and not is_nil(m.id))
  end

  # "pending" means either pending status OR was added but media was removed
  defp maybe_filter_status_with_library(query, "pending") do
    where(query, [i, m], i.status == "pending" or (i.status == "added" and is_nil(m.id)))
  end

  # For other statuses, just filter by the stored status
  defp maybe_filter_status_with_library(query, status) do
    where(query, [i], i.status == ^status)
  end
end
