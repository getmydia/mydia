defmodule Mydia.ImportLists do
  @moduledoc """
  Context for managing import lists.

  Import lists allow users to automatically sync media from external sources like
  TMDB trending/popular lists. This context provides functions for managing lists,
  their items, and syncing operations.
  """

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  alias Mydia.Repo

  alias Mydia.ImportLists.{ImportList, ImportListItem}
  alias Mydia.Media.MediaItem

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
  Creates an import list item, or atomically updates it if it already exists.

  Uses a real `INSERT ... ON CONFLICT` on the `(import_list_id, tmdb_id)` unique
  index rather than a select-then-write, so two syncs racing the same item can
  never have the loser silently drop it (the old select-then-insert/update
  raced the unique constraint and swallowed the resulting changeset error).

  Only the cached display fields (`title`, `year`, `poster_path`) are
  overwritten when an existing row is matched; `discovered_at`, `status`,
  `skip_reason` and `media_item_id` are left exactly as they were.

  Because the same changeset both inserts and (via conflict) updates, every
  call must supply the full set of required fields (`tmdb_id`, `title`,
  `discovered_at`, `import_list_id`), not just the fields that would change.

  Returns `{:ok, item, :created}` when a new row was inserted, `{:ok, item,
  :updated}` when an existing row was matched, or `{:error, changeset}`.
  """
  def upsert_import_list_item(attrs) do
    title = attrs[:title] || attrs["title"]
    year = attrs[:year] || attrs["year"]
    poster_path = attrs[:poster_path] || attrs["poster_path"]

    # Pre-generate the id so created-vs-updated can be told apart afterwards
    # without a race: on conflict, Postgres and SQLite both leave the
    # existing row's id untouched, so the returned id only matches this one
    # when the insert actually happened.
    candidate_id = Ecto.UUID.generate()

    changeset =
      %ImportListItem{}
      |> ImportListItem.changeset(%{
        import_list_id: attrs[:import_list_id] || attrs["import_list_id"],
        tmdb_id: attrs[:tmdb_id] || attrs["tmdb_id"],
        title: title,
        year: year,
        poster_path: poster_path,
        discovered_at: attrs[:discovered_at] || attrs["discovered_at"]
      })
      |> Ecto.Changeset.put_change(:id, candidate_id)

    changeset
    |> Repo.insert(
      on_conflict: [set: [title: title, year: year, poster_path: poster_path]],
      conflict_target: [:import_list_id, :tmdb_id],
      returning: true
    )
    |> case do
      {:ok, %ImportListItem{id: ^candidate_id} = item} -> {:ok, item, :created}
      {:ok, item} -> {:ok, item, :updated}
      {:error, _} = error -> error
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

  # Backoff state (consecutive failure count and the time of the last
  # failure) lives in the existing `config` map rather than as dedicated
  # columns. `config` is already a schema field with no migration needed, and
  # every write below merges into it rather than replacing it wholesale, so
  # it never clobbers the `list_url` some list types also keep there.
  @max_backoff_seconds 24 * 60 * 60

  # 2 ** 32 minutes already dwarfs @max_backoff_seconds, so clamping here costs
  # nothing and keeps :math.pow/2 well clear of the float range it raises on.
  @max_backoff_exponent 32

  @doc """
  Marks an import list sync as successful.

  Updates `last_synced_at`, clears `sync_error`, and resets the consecutive
  failure count so the next sync is scheduled at the normal interval again
  instead of continuing any backoff from prior failures.
  """
  def mark_sync_success(%ImportList{} = import_list) do
    update_import_list(import_list, %{
      last_synced_at: DateTime.utc_now(),
      sync_error: nil,
      config: clear_backoff_state(import_list.config)
    })
  end

  @doc """
  Records a sync error for an import list and applies exponential backoff.

  A failed list used to stay permanently "due": `sync_due?/1` only looked at
  `last_synced_at`, which this function never touched, so a cron tick every
  15 minutes re-enqueued the same failing list forever regardless of its
  configured interval. This now records the failure time and increments a
  consecutive-failure count (both in `config`), and `sync_due?/1` uses them to
  delay the next attempt by `sync_interval * 2^(failures - 1)`, capped at 24
  hours, instead of retrying at the full interval (or immediately) every time.
  """
  def mark_sync_error(%ImportList{} = import_list, error) do
    error_message =
      case error do
        %{message: message} -> message
        message when is_binary(message) -> message
        _ -> inspect(error)
      end

    failures = consecutive_failures(import_list) + 1

    updated_config =
      (import_list.config || %{})
      |> Map.put("consecutive_failures", failures)
      |> Map.put("last_failed_at", DateTime.to_iso8601(DateTime.utc_now()))

    update_import_list(import_list, %{sync_error: error_message, config: updated_config})
  end

  defp clear_backoff_state(config) do
    (config || %{})
    |> Map.delete("consecutive_failures")
    |> Map.delete("last_failed_at")
  end

  defp consecutive_failures(%ImportList{config: %{"consecutive_failures" => n}})
       when is_integer(n) and n > 0,
       do: n

  defp consecutive_failures(%ImportList{}), do: 0

  defp last_failed_at(%ImportList{config: %{"last_failed_at" => value}}) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> dt
      {:error, _} -> nil
    end
  end

  defp last_failed_at(%ImportList{}), do: nil

  # interval * 2^(n-1), capped at 24h. The first failure (n = 1) delays by
  # exactly one interval, which alone fixes "hammered every 15 minutes
  # forever" since sync_due?/1 previously ignored failures entirely; each
  # additional consecutive failure doubles the delay from there.
  defp backoff_delay_seconds(interval_minutes, failures) do
    # Clamp the exponent before it reaches :math.pow/2. The delay is capped at
    # 24 hours anyway, so any exponent past this point is already saturated, and
    # 2 ** 1024 overflows a float and raises ArithmeticError. A list that fails
    # forever accrues roughly one failure per day once the cap is reached, and
    # list_sync_due_lists/0 filters every list through sync_due?/1, so an
    # unclamped raise would eventually stop syncing for all lists, not just the
    # broken one.
    exponent = min(failures - 1, @max_backoff_exponent)
    delay = trunc(interval_minutes * 60 * :math.pow(2, exponent))
    min(delay, @max_backoff_seconds)
  end

  defp backoff_elapsed?(%ImportList{sync_interval: interval} = import_list) do
    case last_failed_at(import_list) do
      # A failure count with no recorded failure time (shouldn't happen in
      # practice, but config is a free-form map) can't compute a delay, so
      # default to due rather than stuck.
      nil ->
        true

      failed_at ->
        delay_seconds = backoff_delay_seconds(interval, consecutive_failures(import_list))
        due_at = DateTime.add(failed_at, delay_seconds, :second)
        DateTime.compare(DateTime.utc_now(), due_at) in [:gt, :eq]
    end
  end

  @doc """
  Checks if an import list is due for sync based on its interval.

  A list with consecutive failures uses the exponential backoff delay from
  its last failure instead of the plain interval from `last_synced_at`; see
  `mark_sync_error/2`.
  """
  def sync_due?(%ImportList{enabled: false}), do: false

  def sync_due?(%ImportList{} = import_list) do
    if consecutive_failures(import_list) > 0 do
      backoff_elapsed?(import_list)
    else
      due_by_interval?(import_list)
    end
  end

  defp due_by_interval?(%ImportList{last_synced_at: nil}), do: true

  defp due_by_interval?(%ImportList{last_synced_at: last_synced, sync_interval: interval}) do
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
    case check_duplicate(item.tmdb_id, import_list.media_type, item.title, item.year) do
      {:duplicate, media_item} ->
        handle_duplicate_item(item, media_item)

      :not_found ->
        fetch_and_create_media_item(item, import_list)
    end
  end

  # Links the item to the media already in the library. A single write: an
  # earlier version wrote mark_item_skipped/2 first and mark_item_added/2
  # right after, which immediately overwrote the skip (mark_item_added/2
  # clears skip_reason), so the row always ended up "added" anyway. That made
  # the write pointless and, worse, made the job's own stats (which reported
  # it as skipped) disagree with what the database actually stored.
  defp handle_duplicate_item(item, media_item) do
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

    case Mydia.Media.create_media_item(attrs) do
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
  Checks if media matching an import list item already exists in the library.

  Looks up by TMDB ID first. Media that entered the library from a filesystem
  scan often has no TMDB ID at all, so a miss falls back to a conservative
  title+year match: normalised (trimmed, case-insensitive) title, an exact
  year match, and only against rows where `tmdb_id` is still `NULL` (a row
  that already carries a *different* TMDB ID is a genuinely different title,
  not a fuzzy match). The fallback only runs when both `title` and `year` are
  given; a `nil` year is treated as too little information to match on safely.

  Returns `{:duplicate, media_item}` if found, `:not_found` otherwise.
  """
  def check_duplicate(tmdb_id, media_type, title \\ nil, year \\ nil)
      when is_integer(tmdb_id) do
    type = normalize_media_check_type(media_type)

    case Repo.get_by(MediaItem, tmdb_id: tmdb_id, type: type) do
      nil -> check_duplicate_by_title_year(type, title, year)
      media_item -> {:duplicate, media_item}
    end
  end

  defp normalize_media_check_type(media_type) do
    case media_type do
      "movie" -> "movie"
      "tv_show" -> "tv_show"
      :movie -> "movie"
      :tv_show -> "tv_show"
      _ -> media_type
    end
  end

  defp check_duplicate_by_title_year(_type, title, year)
       when is_nil(title) or title == "" or is_nil(year) do
    :not_found
  end

  defp check_duplicate_by_title_year(type, title, year) do
    normalized_title = title |> String.trim() |> String.downcase()

    query =
      from(m in MediaItem,
        where:
          m.type == ^type and
            is_nil(m.tmdb_id) and
            m.year == ^year and
            fragment("lower(trim(?))", m.title) == ^normalized_title
      )

    case Repo.one(query) do
      nil -> :not_found
      media_item -> {:duplicate, media_item}
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
        case check_duplicate(item.tmdb_id, import_list.media_type, item.title, item.year) do
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
