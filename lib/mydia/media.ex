defmodule Mydia.Media do
  @moduledoc """
  The Media context handles movies, TV shows, and episodes.
  """

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  require Logger
  alias Mydia.Repo
  alias Mydia.Media.{MediaItem, Episode, CategoryClassifier}
  alias Mydia.Media.Structs.CalendarEntry
  alias Mydia.Metadata.Access, as: MetadataAccess
  alias Mydia.Events

  ## Media Items

  @doc """
  Returns the list of media items.

  ## Options
    - `:type` - Filter by type ("movie" or "tv_show")
    - `:monitored` - Filter by monitored status (true/false)
    - `:category` - Filter by category (atom or string, e.g., :anime_movie or "anime_movie")
    - `:library_path_type` - Filter by library path type (:adult, :music, :books, etc.)
    - `:search` - Search by title (case-insensitive substring match)
    - `:added_since` - Filter to items inserted after this DateTime
    - `:limit` - Maximum number of items to return
    - `:order_by` - Field to order by (:title, :year, or :inserted_at)
    - `:preload` - List of associations to preload
  """
  @spec list_media_items(keyword()) :: [MediaItem.t()]
  def list_media_items(opts \\ []) do
    MediaItem
    |> apply_media_item_filters(opts)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Gets a single media item.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the media item does not exist.
  """
  @spec get_media_item!(binary(), keyword()) :: MediaItem.t()
  def get_media_item!(id, opts \\ []) do
    MediaItem
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Returns one keyset page of media items for the plugin `data-list` host
  function (U5), ordered by `(updated_at, id)`.

  ## Options
    * `:limit` - page size (default 200)
    * `:updated_since` - only items updated at/after this `DateTime`
    * `:after` - `{updated_at, id}` of the last row of the previous page
  """
  @spec list_items_page(keyword()) :: [MediaItem.t()]
  def list_items_page(opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    since = Keyword.get(opts, :updated_since)
    after_cursor = Keyword.get(opts, :after)

    query = from(m in MediaItem, order_by: [asc: m.updated_at, asc: m.id], limit: ^limit)

    query = if since, do: from(m in query, where: m.updated_at >= ^since), else: query

    query =
      case after_cursor do
        {ts, id} ->
          from m in query, where: m.updated_at > ^ts or (m.updated_at == ^ts and m.id > ^id)

        _ ->
          query
      end

    Repo.all(query)
  end

  @doc """
  Gets a single media item by TMDB ID.
  """
  @spec get_media_item_by_tmdb(integer(), keyword()) :: MediaItem.t() | nil
  def get_media_item_by_tmdb(tmdb_id, opts \\ []) do
    MediaItem
    |> where([m], m.tmdb_id == ^tmdb_id)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Gets a single media item by TVDB ID.
  """
  @spec get_media_item_by_tvdb(integer(), keyword()) :: MediaItem.t() | nil
  def get_media_item_by_tvdb(tvdb_id, opts \\ []) do
    MediaItem
    |> where([m], m.tvdb_id == ^tvdb_id)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Finds a media item by external IDs using cascading lookup: IMDB → TVDB → TMDB.

  Accepts a map with atom keys: `%{imdb: id, tvdb: id, tmdb: id}`.
  Returns nil if no match is found.
  """
  @spec find_by_external_ids(map()) :: MediaItem.t() | nil
  def find_by_external_ids(ids) when is_map(ids) do
    imdb = Map.get(ids, :imdb)
    tvdb = Map.get(ids, :tvdb)
    tmdb = Map.get(ids, :tmdb)

    cond do
      imdb -> Repo.get_by(MediaItem, imdb_id: imdb)
      tvdb -> Repo.get_by(MediaItem, tvdb_id: tvdb)
      tmdb -> Repo.get_by(MediaItem, tmdb_id: tmdb)
      true -> nil
    end
  end

  @doc """
  Finds an episode by show ID, season number, and episode number.

  Returns nil if no match is found or if season/episode are not integers.
  """
  @spec find_episode(binary(), integer(), integer()) :: Episode.t() | nil
  def find_episode(show_id, season_number, episode_number)
      when is_integer(season_number) and is_integer(episode_number) do
    Episode
    |> where([e], e.media_item_id == ^show_id)
    |> where([e], e.season_number == ^season_number)
    |> where([e], e.episode_number == ^episode_number)
    |> limit(1)
    |> Repo.one()
  end

  def find_episode(_, _, _), do: nil

  @doc """
  Creates a media item.

  For TV shows, this automatically fetches and creates all episodes from the
  metadata provider. This ensures TV shows are never created without their
  episode data.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
    - `:season_monitoring` - For TV shows, which seasons to fetch ("all", "first", "latest", "none") - defaults to "all"
    - `:skip_episode_refresh` - Skip automatic episode fetching (for tests or special cases) - defaults to false
  """
  @spec create_media_item(map(), keyword()) :: {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t()}
  def create_media_item(attrs \\ %{}, opts \\ []) do
    with {:ok, media_item} <-
           %MediaItem{}
           |> MediaItem.changeset(attrs)
           |> Repo.insert() do
      # Auto-classify the media item based on metadata
      media_item = auto_classify_media_item(media_item)

      # Track event
      actor_type = Keyword.get(opts, :actor_type, :system)
      actor_id = Keyword.get(opts, :actor_id, "media_context")

      # The media_item.added event flows through the plugin dispatcher
      # (Mydia.Plugins.Dispatcher), which replaced the Luerl after_media_added
      # hook (U11). No explicit hook call is needed here.
      Events.media_item_added(media_item, actor_type, actor_id)

      # For TV shows, automatically fetch episodes unless explicitly skipped
      if media_item.type == "tv_show" and not Keyword.get(opts, :skip_episode_refresh, false) do
        season_monitoring = Keyword.get(opts, :season_monitoring, "all")

        case refresh_episodes_for_tv_show(media_item, season_monitoring: season_monitoring) do
          {:ok, count} ->
            Logger.info("Created #{count} episodes for #{media_item.title}")

          {:error, reason} ->
            # Log the error but don't fail the media item creation
            # The show is still usable and episodes can be refreshed later
            Logger.warning("Failed to fetch episodes for #{media_item.title}: #{inspect(reason)}")
        end
      end

      {:ok, media_item}
    end
  end

  @doc """
  Updates a media item.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
    - `:reason` - Description of what was updated (e.g., "Metadata refreshed") - defaults to "Updated"
  """
  @spec update_media_item(MediaItem.t(), map(), keyword()) ::
          {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t()}
  def update_media_item(%MediaItem{} = media_item, attrs, opts \\ []) do
    changeset = MediaItem.changeset(media_item, attrs)

    case Repo.update(changeset) do
      {:ok, updated_media_item} ->
        # Track event with change details
        actor_type = Keyword.get(opts, :actor_type, :system)
        actor_id = Keyword.get(opts, :actor_id, "media_context")
        reason = Keyword.get(opts, :reason, "Updated")
        changes = extract_meaningful_changes(changeset, media_item)

        Events.media_item_updated(updated_media_item, actor_type, actor_id, reason, changes)

        {:ok, updated_media_item}

      error ->
        error
    end
  end

  # Extracts meaningful changes from a changeset for activity logging
  defp extract_meaningful_changes(changeset, original) do
    changes = changeset.changes

    simple_changes =
      changes
      |> Map.take([:title, :original_title, :year])
      |> Enum.map(fn {field, new_value} ->
        old_value = Map.get(original, field)
        {field, %{old: old_value, new: new_value}}
      end)
      |> Map.new()

    # Extract meaningful changes from nested metadata
    metadata_changes =
      if Map.has_key?(changes, :metadata) do
        extract_metadata_changes(original.metadata, changes.metadata)
      else
        %{}
      end

    Map.merge(simple_changes, metadata_changes)
  end

  defp extract_metadata_changes(nil, _new), do: %{metadata: %{old: nil, new: "added"}}
  defp extract_metadata_changes(_old, nil), do: %{}

  defp extract_metadata_changes(old_metadata, new_metadata) do
    # Compare interesting metadata fields
    fields_to_compare = [
      {:overview, "overview"},
      {:poster_path, "poster"},
      {:backdrop_path, "backdrop"},
      {:tagline, "tagline"},
      {:vote_average, "rating"},
      {:runtime, "runtime"},
      {:genres, "genres"}
    ]

    changes =
      Enum.reduce(fields_to_compare, [], fn {field, label}, acc ->
        old_val = MetadataAccess.get(old_metadata, field)
        new_val = MetadataAccess.get(new_metadata, field)

        if values_differ?(old_val, new_val) do
          [{label, format_metadata_change(field, old_val, new_val)} | acc]
        else
          acc
        end
      end)

    # Check cast/crew count changes
    changes = maybe_add_count_change(changes, old_metadata, new_metadata, :cast, "cast")
    changes = maybe_add_count_change(changes, old_metadata, new_metadata, :crew, "crew")

    if changes == [] do
      %{}
    else
      %{metadata_fields: Enum.reverse(changes)}
    end
  end

  defp values_differ?(nil, nil), do: false
  defp values_differ?(nil, ""), do: false
  defp values_differ?("", nil), do: false
  defp values_differ?(old, new), do: old != new

  defp format_metadata_change(:vote_average, old, new) do
    %{old: format_rating(old), new: format_rating(new)}
  end

  defp format_metadata_change(:runtime, old, new) do
    %{old: format_runtime(old), new: format_runtime(new)}
  end

  defp format_metadata_change(:genres, old, new) do
    %{old: format_genres(old), new: format_genres(new)}
  end

  defp format_metadata_change(_field, old, new) do
    %{old: present?(old), new: present?(new)}
  end

  defp format_rating(nil), do: nil
  defp format_rating(val) when is_number(val), do: Float.round(val / 1, 1)
  defp format_rating(val), do: val

  defp format_runtime(nil), do: nil
  defp format_runtime(minutes) when is_integer(minutes), do: "#{minutes}m"
  defp format_runtime(val), do: val

  defp format_genres(nil), do: nil
  defp format_genres([]), do: nil
  defp format_genres(genres) when is_list(genres), do: Enum.count(genres)
  defp format_genres(val), do: val

  defp present?(nil), do: nil
  defp present?(""), do: nil
  defp present?(_), do: true

  defp maybe_add_count_change(changes, old_metadata, new_metadata, field, label) do
    old_count = count_list(MetadataAccess.get(old_metadata, field))
    new_count = count_list(MetadataAccess.get(new_metadata, field))

    if old_count != new_count do
      [{label, %{old: old_count, new: new_count}} | changes]
    else
      changes
    end
  end

  defp count_list(nil), do: 0
  defp count_list(list) when is_list(list), do: length(list)
  defp count_list(_), do: 0

  @doc """
  Deletes a media item.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
    - `:delete_files` - Whether to delete physical files from disk (default: false)

  When `:delete_files` is true, will delete all associated media files from disk
  before removing the database records. When false (default), only removes database
  records and preserves files on disk.
  """
  @spec delete_media_item(MediaItem.t(), keyword()) ::
          {:ok, MediaItem.t(), non_neg_integer()} | {:error, Ecto.Changeset.t()}
  def delete_media_item(%MediaItem{} = media_item, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    Logger.info("delete_media_item called",
      media_item_id: media_item.id,
      title: media_item.title,
      delete_files: delete_files
    )

    # Load all media files (movie files + episode files) into memory *before*
    # deleting the record, so their paths stay resolvable after the cascade
    # delete. We remove them from disk only after the record delete succeeds:
    # a failed DB delete then leaves the disk untouched (nothing lost).
    all_media_files =
      if delete_files do
        media_item_with_files =
          MediaItem
          |> where([m], m.id == ^media_item.id)
          |> preload(media_files: :library_path, episodes: [media_files: :library_path])
          |> Repo.one!()

        media_item_with_files.media_files ++
          Enum.flat_map(media_item_with_files.episodes, & &1.media_files)
      else
        []
      end

    # Track event before deletion (we need the media_item data)
    actor_type = Keyword.get(opts, :actor_type, :system)
    actor_id = Keyword.get(opts, :actor_id, "media_context")

    Events.media_item_removed(media_item, actor_type, actor_id)

    # Delete the media item (and cascade delete all related DB records)
    case Repo.delete(media_item) do
      {:ok, deleted} ->
        {:ok, deleted, delete_files_from_disk(delete_files, all_media_files, media_item)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  # Removes the given media files from disk after the record delete succeeded.
  # Returns the number of files that could not be removed (0 when not deleting
  # files), which callers surface to the user.
  defp delete_files_from_disk(false, _media_files, _media_item), do: 0

  defp delete_files_from_disk(true, media_files, media_item) do
    Logger.info("Attempting to delete physical files",
      media_item_id: media_item.id,
      file_count: length(media_files),
      file_paths: Enum.map(media_files, & &1.path)
    )

    {:ok, success_count, error_count} =
      Mydia.Library.delete_media_files_from_disk(media_files)

    Logger.info("Deleted #{success_count} files from disk (#{error_count} errors)",
      media_item_id: media_item.id,
      title: media_item.title
    )

    error_count
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking media item changes.
  """
  @spec change_media_item(MediaItem.t(), map()) :: Ecto.Changeset.t()
  def change_media_item(%MediaItem{} = media_item, attrs \\ %{}) do
    MediaItem.changeset(media_item, attrs)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking category changes on a media item.
  """
  @spec change_media_item_category(MediaItem.t(), map()) :: Ecto.Changeset.t()
  def change_media_item_category(%MediaItem{} = media_item, attrs \\ %{}) do
    media_item
    |> Ecto.Changeset.cast(attrs, [:category, :category_override])
    |> Ecto.Changeset.validate_required([:category])
    |> Ecto.Changeset.validate_inclusion(:category, [
      "movie",
      "anime_movie",
      "cartoon_movie",
      "tv_show",
      "anime_series",
      "cartoon_series"
    ])
  end

  @doc """
  Updates the monitored status for multiple media items.

  Returns `{:ok, count}` where count is the number of updated items,
  or `{:error, reason}` if the transaction fails.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
  """
  @spec update_media_items_monitored([binary()], boolean(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def update_media_items_monitored(ids, monitored, opts \\ []) when is_list(ids) do
    Repo.transaction(fn ->
      # Fetch media items before update to track events
      media_items =
        MediaItem
        |> where([m], m.id in ^ids)
        |> Repo.all()

      # Perform the update
      {count, _} =
        MediaItem
        |> where([m], m.id in ^ids)
        |> Repo.update_all(set: [monitored: monitored, updated_at: DateTime.utc_now()])

      # Track events for each media item
      actor_type = Keyword.get(opts, :actor_type, :system)
      actor_id = Keyword.get(opts, :actor_id, "media_context")

      Enum.each(media_items, fn media_item ->
        Events.media_item_monitoring_changed(media_item, monitored, actor_type, actor_id)
      end)

      count
    end)
  end

  @doc """
  Updates multiple media items with the given attributes in a transaction.

  Only updates non-nil attributes. Returns `{:ok, count}` on success
  where count is the number of updated items.
  """
  @spec update_media_items_batch([binary()], map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def update_media_items_batch(ids, attrs) when is_list(ids) and is_map(attrs) do
    Repo.transaction(fn ->
      # Build the update list, only including non-nil values
      updates =
        attrs
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Enum.into(%{})
        |> Map.put(:updated_at, DateTime.utc_now())

      if map_size(updates) > 1 do
        # More than just updated_at
        MediaItem
        |> where([m], m.id in ^ids)
        |> Repo.update_all(set: Map.to_list(updates))
        |> elem(0)
      else
        0
      end
    end)
  end

  @doc """
  Deletes multiple media items in a transaction.

  ## Options
    - `:delete_files` - Whether to delete physical files from disk (default: false)

  Returns `{:ok, count}` where count is the number of deleted items,
  or `{:error, reason}` if the transaction fails.

  When `:delete_files` is true, the database records are deleted first and the
  associated files are removed from disk afterwards (so a failed delete leaves
  the disk untouched). When false (default), only removes database records and
  preserves files on disk.
  """
  @spec delete_media_items([binary()], keyword()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, term()}
  def delete_media_items(ids, opts \\ []) when is_list(ids) do
    delete_files = Keyword.get(opts, :delete_files, false)

    result =
      Repo.transaction(fn ->
        # Load all media files into memory before deleting the records so their
        # paths stay resolvable after the cascade delete.
        all_media_files =
          if delete_files do
            MediaItem
            |> where([m], m.id in ^ids)
            |> preload(media_files: :library_path, episodes: [media_files: :library_path])
            |> Repo.all()
            |> Enum.flat_map(fn item ->
              item.media_files ++ Enum.flat_map(item.episodes, & &1.media_files)
            end)
          else
            []
          end

        # Delete the media items (and cascade delete all related DB records).
        count =
          MediaItem
          |> where([m], m.id in ^ids)
          |> Repo.delete_all()
          |> elem(0)

        # Only after the records are gone do we remove the files from disk.
        # error_count is the number of files that could not be removed.
        error_count =
          if delete_files do
            {:ok, success_count, error_count} =
              Mydia.Library.delete_media_files_from_disk(all_media_files)

            Logger.info(
              "Batch deleted #{success_count} files from disk (#{error_count} errors)",
              media_item_count: count
            )

            error_count
          else
            0
          end

        {count, error_count}
      end)

    case result do
      {:ok, {count, error_count}} -> {:ok, count, error_count}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Returns the count of movies in the library.
  """
  @spec count_movies() :: non_neg_integer()
  def count_movies do
    MediaItem
    |> where([m], m.type == "movie")
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the count of TV shows in the library.
  """
  @spec count_tv_shows() :: non_neg_integer()
  def count_tv_shows do
    MediaItem
    |> where([m], m.type == "tv_show")
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the count of media items by library path type.

  This counts media items that have files in library paths of the specified type.
  Includes both direct media files (for movies) and episode media files (for TV shows).
  """
  @spec count_by_library_path_type(atom()) :: non_neg_integer()
  def count_by_library_path_type(library_type) do
    MediaItem
    |> filter_by_library_path_type(library_type)
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns a map of provider IDs to library status for efficient lookup.

  Returns a map where:
  - TMDB IDs are integer keys: `12345 => %{...}`
  - TVDB IDs are tuple keys: `{:tvdb, 67890} => %{...}`

  Values are maps with:
  - `:in_library` - boolean
  - `:monitored` - boolean (if in library)
  - `:type` - "movie" or "tv_show" (if in library)
  - `:id` - database ID (if in library)

  ## Examples

      iex> get_library_status_map()
      %{
        12345 => %{in_library: true, monitored: true, type: "movie", id: 1},
        {:tvdb, 67890} => %{in_library: true, monitored: false, type: "tv_show", id: 2}
      }
  """
  @spec get_library_status_map() :: map()
  def get_library_status_map do
    MediaItem
    |> where([m], not is_nil(m.tmdb_id) or not is_nil(m.tvdb_id))
    |> select([m], {m.tmdb_id, m.tvdb_id, m.monitored, m.type, m.id})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {tmdb_id, tvdb_id, monitored, type, id}, acc ->
      entry = %{in_library: true, monitored: monitored, type: type, id: id}

      acc =
        if tmdb_id, do: Map.put(acc, tmdb_id, entry), else: acc

      if tvdb_id, do: Map.put(acc, {:tvdb, tvdb_id}, entry), else: acc
    end)
  end

  ## Episodes

  @doc """
  Returns the list of episodes for a media item.

  ## Options
    - `:season` - Filter by season number
    - `:monitored` - Filter by monitored status (true/false)
    - `:preload` - List of associations to preload
  """
  @spec list_episodes(binary(), keyword()) :: [Episode.t()]
  def list_episodes(media_item_id, opts \\ []) do
    Episode
    |> where([e], e.media_item_id == ^media_item_id)
    |> apply_episode_filters(opts)
    |> maybe_preload(opts[:preload])
    |> order_by([e], asc: e.season_number, asc: e.episode_number)
    |> Repo.all()
  end

  @doc """
  Gets a single episode.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the episode does not exist.
  """
  @spec get_episode!(binary(), keyword()) :: Episode.t()
  def get_episode!(id, opts \\ []) do
    Episode
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a single episode by media item ID, season, and episode number.
  """
  @spec get_episode_by_number(binary(), integer(), integer(), keyword()) :: Episode.t() | nil
  def get_episode_by_number(media_item_id, season_number, episode_number, opts \\ []) do
    Episode
    |> where([e], e.media_item_id == ^media_item_id)
    |> where([e], e.season_number == ^season_number)
    |> where([e], e.episode_number == ^episode_number)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Gets the next episode for the given episode.
  Returns the next episode in the same season if available,
  otherwise returns the first episode of the next season.
  Returns nil if there is no next episode.
  """
  @spec get_next_episode(Episode.t(), keyword()) :: Episode.t() | nil
  def get_next_episode(%Episode{} = episode, opts \\ []) do
    # Try to get next episode in same season first
    next_in_season =
      Episode
      |> where([e], e.media_item_id == ^episode.media_item_id)
      |> where([e], e.season_number == ^episode.season_number)
      |> where([e], e.episode_number > ^episode.episode_number)
      |> order_by([e], asc: e.episode_number)
      |> limit(1)
      |> maybe_preload(opts[:preload])
      |> Repo.one()

    case next_in_season do
      nil ->
        # No more episodes in current season, try next season
        Episode
        |> where([e], e.media_item_id == ^episode.media_item_id)
        |> where([e], e.season_number > ^episode.season_number)
        |> order_by([e], asc: e.season_number, asc: e.episode_number)
        |> limit(1)
        |> maybe_preload(opts[:preload])
        |> Repo.one()

      episode ->
        episode
    end
  end

  @doc """
  Creates an episode.
  """
  @spec create_episode(map()) :: {:ok, Episode.t()} | {:error, Ecto.Changeset.t()}
  def create_episode(attrs \\ %{}) do
    %Episode{}
    |> Episode.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an episode.
  """
  @spec update_episode(Episode.t(), map()) :: {:ok, Episode.t()} | {:error, Ecto.Changeset.t()}
  def update_episode(%Episode{} = episode, attrs) do
    episode
    |> Episode.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the monitored status for all episodes in a season.

  Returns `{:ok, count}` where count is the number of updated episodes,
  or `{:error, reason}` if the transaction fails.

  ## Examples

      iex> update_season_monitoring(media_item_id, 1, true)
      {:ok, 12}

      iex> update_season_monitoring(media_item_id, 2, false)
      {:ok, 8}
  """
  @spec update_season_monitoring(binary(), integer(), boolean()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def update_season_monitoring(media_item_id, season_number, monitored)
      when is_boolean(monitored) do
    Repo.transaction(fn ->
      Episode
      |> where([e], e.media_item_id == ^media_item_id)
      |> where([e], e.season_number == ^season_number)
      |> Repo.update_all(set: [monitored: monitored, updated_at: DateTime.utc_now()])
      |> elem(0)
    end)
  end

  @monitoring_presets [:all, :future, :missing, :existing, :first_season, :latest_season, :none]

  @doc """
  Returns the list of valid monitoring presets.
  """
  @spec monitoring_presets() :: [atom()]
  def monitoring_presets, do: @monitoring_presets

  @doc """
  Applies a monitoring preset to all episodes of a TV show.

  This function:
  1. Determines which episodes should be monitored based on the preset
  2. Updates all episode monitored states accordingly
  3. Saves the preset to the media_item record

  ## Presets

  - `:all` - Monitor all episodes (except specials)
  - `:future` - Only episodes where air_date > today
  - `:missing` - Episodes without files OR air_date > today
  - `:existing` - Only episodes that have associated media files
  - `:first_season` - Only season 1 episodes
  - `:latest_season` - Latest season number + any future seasons
  - `:none` - No episodes monitored

  ## Returns

  - `{:ok, media_item, count}` - Success with updated media_item and count of episodes changed
  - `{:error, reason}` - Error with reason

  ## Examples

      iex> apply_monitoring_preset(media_item, :all)
      {:ok, %MediaItem{monitoring_preset: :all}, 24}

      iex> apply_monitoring_preset(media_item, :future)
      {:ok, %MediaItem{monitoring_preset: :future}, 8}
  """
  @spec apply_monitoring_preset(MediaItem.t(), atom()) ::
          {:ok, MediaItem.t(), non_neg_integer()} | {:error, term()}
  def apply_monitoring_preset(%MediaItem{type: "tv_show"} = media_item, preset)
      when preset in @monitoring_presets do
    Repo.transaction(fn ->
      # Get all episodes for this media item with media_files preloaded
      episodes = list_episodes(media_item.id, preload: [:media_files])

      # Determine which episodes should be monitored based on the preset
      {to_monitor, to_unmonitor} = partition_episodes_by_preset(episodes, preset)

      # Update episodes that should be monitored
      monitored_count =
        if to_monitor != [] do
          monitored_ids = Enum.map(to_monitor, & &1.id)

          Episode
          |> where([e], e.id in ^monitored_ids)
          |> Repo.update_all(set: [monitored: true, updated_at: DateTime.utc_now()])
          |> elem(0)
        else
          0
        end

      # Update episodes that should not be monitored
      unmonitored_count =
        if to_unmonitor != [] do
          unmonitored_ids = Enum.map(to_unmonitor, & &1.id)

          Episode
          |> where([e], e.id in ^unmonitored_ids)
          |> Repo.update_all(set: [monitored: false, updated_at: DateTime.utc_now()])
          |> elem(0)
        else
          0
        end

      # Save the preset to the media item
      {:ok, updated_media_item} =
        media_item
        |> MediaItem.changeset(%{monitoring_preset: preset})
        |> Repo.update()

      # Track the monitoring preset change
      Events.media_item_updated(
        updated_media_item,
        :user,
        "media_context",
        "Monitoring preset changed to #{preset}"
      )

      {updated_media_item, monitored_count + unmonitored_count}
    end)
    |> case do
      {:ok, {media_item, count}} -> {:ok, media_item, count}
      {:error, reason} -> {:error, reason}
    end
  end

  def apply_monitoring_preset(%MediaItem{type: type}, _preset) do
    {:error, {:invalid_type, "apply_monitoring_preset only works for TV shows, got #{type}"}}
  end

  def apply_monitoring_preset(_media_item, preset) when preset not in @monitoring_presets do
    {:error, {:invalid_preset, "Unknown preset: #{preset}"}}
  end

  # Partition episodes into those to monitor and those to unmonitor based on preset
  defp partition_episodes_by_preset(episodes, :all) do
    # Monitor all episodes (except season 0 specials)
    {to_monitor, to_unmonitor} =
      Enum.split_with(episodes, fn ep -> ep.season_number > 0 end)

    {to_monitor, to_unmonitor}
  end

  defp partition_episodes_by_preset(episodes, :none) do
    # Unmonitor all episodes
    {[], episodes}
  end

  defp partition_episodes_by_preset(episodes, :future) do
    today = Date.utc_today()

    Enum.split_with(episodes, fn ep ->
      ep.air_date && Date.compare(ep.air_date, today) == :gt
    end)
  end

  defp partition_episodes_by_preset(episodes, :missing) do
    today = Date.utc_today()

    Enum.split_with(episodes, fn ep ->
      has_no_files = Enum.empty?(ep.media_files)
      is_future = ep.air_date && Date.compare(ep.air_date, today) == :gt
      has_no_files || is_future
    end)
  end

  defp partition_episodes_by_preset(episodes, :existing) do
    Enum.split_with(episodes, fn ep ->
      not Enum.empty?(ep.media_files)
    end)
  end

  defp partition_episodes_by_preset(episodes, :first_season) do
    Enum.split_with(episodes, fn ep ->
      ep.season_number == 1
    end)
  end

  defp partition_episodes_by_preset(episodes, :latest_season) do
    # Find the latest season number (excluding specials)
    latest_season =
      episodes
      |> Enum.filter(&(&1.season_number > 0))
      |> Enum.map(& &1.season_number)
      |> Enum.max(fn -> 0 end)

    Enum.split_with(episodes, fn ep ->
      ep.season_number >= latest_season && ep.season_number > 0
    end)
  end

  @doc """
  Deletes an episode.
  """
  @spec delete_episode(Episode.t()) :: {:ok, Episode.t()} | {:error, Ecto.Changeset.t()}
  def delete_episode(%Episode{} = episode) do
    Repo.delete(episode)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking episode changes.
  """
  @spec change_episode(Episode.t(), map()) :: Ecto.Changeset.t()
  def change_episode(%Episode{} = episode, attrs \\ %{}) do
    Episode.changeset(episode, attrs)
  end

  @doc """
  Gets aggregate status for a media item (TV show or movie).

  For TV shows, returns status based on all episodes:
  - `:not_monitored` - Media item not monitored
  - `:downloaded` - All monitored episodes downloaded
  - `:partial` - Some episodes downloaded, some missing
  - `:downloading` - Has active downloads
  - `:missing` - No episodes downloaded
  - `:upcoming` - All episodes are upcoming

  For movies, returns simple status based on media files and downloads.

  Returns tuple: `{status, %{downloaded: count, total: count}}` for TV shows
  or `{status, nil}` for movies.

  ## Examples

      iex> get_media_status(%MediaItem{type: "tv_show", monitored: true, episodes: [...]})
      {:partial, %{downloaded: 5, total: 24}}

      iex> get_media_status(%MediaItem{type: "movie", monitored: true})
      {:downloaded, nil}
  """
  @spec get_media_status(MediaItem.t()) :: {atom(), map() | nil}
  def get_media_status(%MediaItem{type: "movie", monitored: false} = media_item) do
    # For non-monitored movies, include file count information
    file_count = length(media_item.media_files)
    {:not_monitored, %{has_files: file_count > 0, file_count: file_count}}
  end

  def get_media_status(%MediaItem{type: "movie"} = media_item) do
    has_files = length(media_item.media_files) > 0

    has_downloads =
      length(media_item.downloads) > 0 &&
        Enum.any?(media_item.downloads, &download_active?/1)

    status =
      cond do
        has_files -> :downloaded
        has_downloads -> :downloading
        true -> :missing
      end

    {status, nil}
  end

  def get_media_status(%MediaItem{type: "tv_show", monitored: false, episodes: episodes}) do
    # For non-monitored TV shows, still show episode counts
    total_episodes = length(episodes)
    downloaded_count = Enum.count(episodes, fn ep -> length(ep.media_files) > 0 end)

    {:not_monitored, %{downloaded: downloaded_count, total: total_episodes}}
  end

  def get_media_status(%MediaItem{type: "tv_show", episodes: episodes}) do
    monitored_episodes = Enum.filter(episodes, & &1.monitored)
    total_monitored = length(monitored_episodes)

    if total_monitored == 0 do
      # No monitored episodes - show all episodes count instead
      total_episodes = length(episodes)
      downloaded_count = Enum.count(episodes, fn ep -> length(ep.media_files) > 0 end)
      {:not_monitored, %{downloaded: downloaded_count, total: total_episodes}}
    else
      downloaded_count =
        monitored_episodes
        |> Enum.count(fn ep -> length(ep.media_files) > 0 end)

      has_active_downloads =
        monitored_episodes
        |> Enum.any?(fn ep ->
          Enum.any?(ep.downloads, &download_active?/1)
        end)

      all_upcoming =
        monitored_episodes
        |> Enum.all?(fn ep ->
          ep.air_date && Date.compare(ep.air_date, Date.utc_today()) == :gt
        end)

      status =
        cond do
          downloaded_count == total_monitored -> :downloaded
          has_active_downloads -> :downloading
          all_upcoming -> :upcoming
          downloaded_count > 0 -> :partial
          true -> :missing
        end

      {status, %{downloaded: downloaded_count, total: total_monitored}}
    end
  end

  @doc """
  Re-fetches metadata from the provider and updates the media item.

  Determines the provider (TVDB/TMDB) from the media item's IDs,
  fetches fresh metadata via `Metadata.fetch_by_id/3` (uncached),
  and updates the media item's metadata field. For TV shows, also
  refreshes episodes.

  ## Returns
    - `{:ok, media_item}` - Updated media item
    - `{:error, reason}` - Error reason
  """
  @spec refresh_metadata(MediaItem.t(), map() | nil) ::
          {:ok, MediaItem.t()} | {:error, term()}
  def refresh_metadata(%MediaItem{} = media_item, config \\ nil) do
    alias Mydia.Metadata

    config = config || Metadata.default_relay_config()
    media_type = if media_item.type == "tv_show", do: :tv_show, else: :movie

    {provider_id, provider_source} = refresh_provider_preference(media_item)

    if is_nil(provider_id) do
      {:error, :missing_provider_id}
    else
      fetch_opts = [
        media_type: media_type,
        provider: provider_source,
        append_to_response: ["credits", "images", "videos", "keywords"]
      ]

      case Metadata.fetch_by_id(config, provider_id, fetch_opts) do
        {:ok, full_metadata} ->
          attrs = %{metadata: full_metadata}

          case update_media_item(media_item, attrs, reason: "Metadata refreshed from provider") do
            {:ok, updated_item} = result ->
              # Regenerate NFO files if enabled for any library path
              Mydia.Metadata.NfoWriter.maybe_write_nfos(updated_item)
              result

            error ->
              error
          end

        {:error, reason} ->
          Logger.warning("Failed to refresh metadata for #{media_item.title}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # Resolve the `{provider_id, provider_source}` a refresh should fetch from.
  #
  # `metadata_source` is the authoritative provenance recorded when an item was
  # matched under per-library provider selection, so it wins even when a
  # back-filled id for the other provider is also present (e.g. a TMDB-sourced
  # show that carries a discovered `tvdb_id`). Only when it is absent do we fall
  # back to the legacy TVDB-precedence rule (prefer `tvdb_id`, then `tmdb_id`).
  defp refresh_provider_preference(%MediaItem{metadata_source: :tmdb, tmdb_id: tmdb_id})
       when not is_nil(tmdb_id),
       do: {to_string(tmdb_id), :tmdb}

  defp refresh_provider_preference(%MediaItem{metadata_source: :tvdb, tvdb_id: tvdb_id})
       when not is_nil(tvdb_id),
       do: {to_string(tvdb_id), :tvdb}

  defp refresh_provider_preference(%MediaItem{tvdb_id: tvdb_id}) when not is_nil(tvdb_id),
    do: {to_string(tvdb_id), :tvdb}

  defp refresh_provider_preference(%MediaItem{tmdb_id: tmdb_id}) when not is_nil(tmdb_id),
    do: {to_string(tmdb_id), :tmdb}

  defp refresh_provider_preference(%MediaItem{}), do: {nil, nil}

  @doc """
  Refreshes episodes for a TV show by fetching metadata and creating missing episodes.

  This function is useful for:
  - TV shows added before season metadata was included
  - Manually refreshing episodes when new seasons are available
  - Fixing TV shows with missing episode data

  ## Parameters
    - `media_item` - The TV show media item (must be type "tv_show")
    - `opts` - Options for episode creation
      - `:season_monitoring` - Which seasons to fetch ("all", "first", "latest", "none")

  ## Returns
    - `{:ok, count}` - Number of episodes created
    - `{:error, reason}` - Error reason

  ## Examples

      iex> refresh_episodes_for_tv_show(media_item)
      {:ok, 236}

      iex> refresh_episodes_for_tv_show(media_item, season_monitoring: "latest")
      {:ok, 12}
  """
  @spec refresh_episodes_for_tv_show(MediaItem.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def refresh_episodes_for_tv_show(media_item, opts \\ [])

  def refresh_episodes_for_tv_show(%MediaItem{type: "tv_show"} = media_item, opts) do
    alias Mydia.Metadata

    season_monitoring = Keyword.get(opts, :season_monitoring, "all")
    config = Metadata.default_relay_config()

    # Resolve the provider to fetch from. `metadata_source` (when set) is the
    # authoritative provenance; only fall back to the legacy TVDB-precedence
    # rule and the stored metadata provider_id when it is absent.
    {provider_id, provider_source} =
      case refresh_provider_preference(media_item) do
        {nil, nil} ->
          case media_item.metadata do
            %{"provider_id" => id} when is_binary(id) -> {id, :tmdb}
            _ -> {nil, nil}
          end

        pair ->
          pair
      end

    # If we have a TMDB ID but no TVDB ID, try to discover the TVDB ID so we can
    # use the preferred TVDB provider for TV shows. Skip this when the show has
    # an explicit `metadata_source` — a TMDB-sourced show must not be silently
    # switched to TVDB on refresh.
    {provider_id, provider_source, media_item} =
      if provider_source == :tmdb and is_nil(media_item.tvdb_id) and
           is_nil(media_item.metadata_source) do
        maybe_discover_tvdb_id(media_item, provider_id, config)
      else
        {provider_id, provider_source, media_item}
      end

    # If no provider ID, try to recover it by searching by title
    {provider_id, provider_source, media_item} =
      if is_nil(provider_id) or provider_id == "" do
        case do_recover_provider_id_by_title(media_item, :tv_show, config) do
          {:ok, recovered_id, updated_item} ->
            # Recovery searches TVDB for TV shows
            source = if updated_item.tvdb_id, do: :tvdb, else: :tmdb
            {to_string(recovered_id), source, updated_item}

          {:error, _reason} ->
            {nil, nil, media_item}
        end
      else
        {provider_id, provider_source, media_item}
      end

    if is_nil(provider_id) or provider_id == "" do
      {:error, :missing_provider_id}
    else
      # Check if we should skip season refresh based on threshold
      if should_skip_season_refresh?(media_item) do
        Logger.info(
          "Skipping season refresh for #{media_item.title} - recently refreshed at #{media_item.seasons_refreshed_at}"
        )

        # Count existing episodes instead
        episode_count =
          Episode
          |> where([e], e.media_item_id == ^media_item.id)
          |> Repo.aggregate(:count)

        {:ok, episode_count}
      else
        # Fetch fresh metadata to get seasons info
        config = Metadata.default_relay_config()

        case Metadata.fetch_by_id(config, provider_id,
               media_type: :tv_show,
               provider: provider_source
             ) do
          {:ok, metadata} ->
            # Get seasons from metadata struct
            seasons = metadata.seasons || []

            Logger.info(
              "Fetching episodes for TV show: #{media_item.title}, found #{length(seasons)} seasons in metadata"
            )

            # Filter seasons based on monitoring preference
            seasons_to_fetch =
              case season_monitoring do
                "all" -> seasons
                "first" -> Enum.take(seasons, 1)
                "latest" -> Enum.take(seasons, -1)
                "none" -> []
                _ -> seasons
              end

            # Invalidate season cache to ensure fresh data with translations
            has_tvdb = not is_nil(media_item.tvdb_id)

            Enum.each(seasons_to_fetch, fn season ->
              tvdb_season_id =
                if has_tvdb, do: Map.get(season, :tvdb_season_id), else: nil

              # Use the configured language so the deleted key matches the one
              # fetch_season_cached writes under (it now keys by configured
              # language, not a hardcoded "en-US").
              cache_key =
                Metadata.build_season_cache_key(
                  provider_id,
                  season.season_number,
                  Metadata.metadata_language(),
                  tvdb_season_id
                )

              Mydia.Metadata.Cache.delete(cache_key)
            end)

            # Fetch and create episodes for each season
            episode_count =
              Enum.reduce(seasons_to_fetch, 0, fn season, count ->
                # Skip season 0 (specials) unless explicitly monitoring all
                if season.season_number == 0 and season_monitoring != "all" do
                  count
                else
                  Logger.info("Processing episodes for season #{season.season_number}")

                  case create_episodes_for_season(media_item, season, config) do
                    {:ok, created} ->
                      Logger.info(
                        "Processed #{created} episodes for season #{season.season_number}"
                      )

                      count + created

                    {:error, reason} ->
                      Logger.error(
                        "Failed to create episodes for season #{season.season_number}: #{inspect(reason)}"
                      )

                      count
                  end
                end
              end)

            Logger.info("Total episodes processed: #{episode_count}")

            # Update seasons_refreshed_at timestamp
            update_media_item(media_item, %{seasons_refreshed_at: DateTime.utc_now()},
              reason: "Season metadata refreshed"
            )

            {:ok, episode_count}

          {:error, reason} ->
            {:error, reason}
        end
      end
    end
  end

  def refresh_episodes_for_tv_show(%MediaItem{type: type}, _opts) do
    {:error, {:invalid_type, "Expected tv_show, got #{type}"}}
  end

  ## Calendar

  @doc """
  Returns episodes with air dates in the specified date range.
  Only returns episodes for monitored media items by default.

  ## Options
    - `:preload` - List of associations to preload
    - `:monitored` - Filter by media item monitored status (default: true, nil for all)
  """
  @spec list_episodes_by_air_date(Date.t(), Date.t(), keyword()) :: [CalendarEntry.t()]
  def list_episodes_by_air_date(start_date, end_date, opts \\ []) do
    monitored = Keyword.get(opts, :monitored, true)

    query =
      Episode
      |> join(:inner, [e], m in MediaItem, on: e.media_item_id == m.id)
      |> where([e, m], not is_nil(e.air_date))
      |> where([e, m], e.air_date >= ^start_date and e.air_date <= ^end_date)

    query =
      if is_nil(monitored) do
        query
      else
        where(query, [e, m], m.monitored == ^monitored)
      end

    query
    |> select([e, m], %{
      id: e.id,
      type: "episode",
      air_date: e.air_date,
      title: e.title,
      season_number: e.season_number,
      episode_number: e.episode_number,
      media_item_id: m.id,
      media_item_title: m.title,
      media_item_type: m.type,
      has_files:
        fragment(
          "CASE WHEN EXISTS(SELECT 1 FROM media_files WHERE episode_id = ?) THEN true ELSE false END",
          e.id
        ),
      has_downloads:
        fragment(
          "CASE WHEN EXISTS(SELECT 1 FROM downloads WHERE episode_id = ?) THEN true ELSE false END",
          e.id
        )
    })
    |> order_by([e, m], asc: e.air_date, asc: m.title)
    |> Repo.all()
    |> Enum.map(fn entry ->
      CalendarEntry.new_episode(
        id: entry.id,
        air_date: entry.air_date,
        title: entry.title,
        season_number: entry.season_number,
        episode_number: entry.episode_number,
        media_item_id: entry.media_item_id,
        media_item_title: entry.media_item_title,
        media_item_type: entry.media_item_type,
        # SQLite returns 0/1 for booleans, convert to proper Elixir booleans
        has_files: entry.has_files == 1,
        has_downloads: entry.has_downloads == 1
      )
    end)
  end

  @doc """
  Returns monitored movies with release dates in the specified date range from metadata.
  Movies must have a release_date in their metadata field.

  ## Options
    - `:monitored` - Filter by monitored status (default: true, nil for all)
  """
  @spec list_movies_by_release_date(Date.t(), Date.t(), keyword()) :: [CalendarEntry.t()]
  def list_movies_by_release_date(start_date, end_date, opts \\ []) do
    monitored = Keyword.get(opts, :monitored, true)

    query =
      MediaItem
      |> where([m], m.type == "movie")
      |> where([m], ^Mydia.DB.json_is_not_null(:metadata, "$.release_date"))

    query =
      if is_nil(monitored) do
        query
      else
        where(query, [m], m.monitored == ^monitored)
      end

    query
    |> Repo.all()
    |> Enum.filter(fn item ->
      release_date = item.metadata && item.metadata.release_date

      release_date != nil and
        Date.compare(release_date, start_date) != :lt and
        Date.compare(release_date, end_date) != :gt
    end)
    |> Enum.map(fn item ->
      has_files =
        Repo.exists?(from f in Mydia.Library.MediaFile, where: f.media_item_id == ^item.id)

      has_downloads =
        Repo.exists?(from d in Mydia.Downloads.Download, where: d.media_item_id == ^item.id)

      CalendarEntry.new_movie(
        id: item.id,
        air_date: item.metadata.release_date,
        title: item.title,
        media_item_id: item.id,
        media_item_title: item.title,
        media_item_type: item.type,
        has_files: has_files,
        has_downloads: has_downloads
      )
    end)
  end

  @doc """
  Upserts episodes from season data into the database.

  Creates new episodes or updates existing ones with fresh metadata from the
  provider. This is the single source of truth for episode creation/update
  from season data — all callers should use this instead of duplicating logic.

  ## Options
    - `:monitor_fn` - Function `(season_number, air_date) -> boolean` to determine
      if a new episode should be monitored. Defaults to monitoring all non-special episodes.
  ## Returns
    - `{:ok, count}` - Number of episodes processed (created + updated)
  """
  @spec upsert_episodes_from_season(MediaItem.t(), struct(), keyword()) ::
          {:ok, non_neg_integer()}
  def upsert_episodes_from_season(media_item, season_data, opts \\ []) do
    default_monitor = fn season_num, _air_date -> season_num > 0 end
    monitor_fn = Keyword.get(opts, :monitor_fn, default_monitor)

    episodes = season_data.episodes || []

    count =
      Enum.reduce(episodes, 0, fn episode, acc ->
        season_num = episode.season_number
        episode_num = episode.episode_number

        # Skip if season or episode number is nil
        if is_nil(season_num) or is_nil(episode_num) do
          acc
        else
          existing = get_episode_by_number(media_item.id, season_num, episode_num)

          air_date = parse_air_date(episode.air_date)

          if is_nil(existing) do
            should_monitor = monitor_fn.(season_num, air_date)

            case create_episode(%{
                   media_item_id: media_item.id,
                   season_number: season_num,
                   episode_number: episode_num,
                   title: episode.name,
                   air_date: air_date,
                   metadata: Map.from_struct(episode),
                   monitored: should_monitor
                 }) do
              {:ok, _episode} -> acc + 1
              {:error, _changeset} -> acc
            end
          else
            # Update existing episode with fresh metadata
            case update_episode(existing, %{
                   title: episode.name,
                   air_date: air_date,
                   metadata: Map.from_struct(episode)
                 }) do
              {:ok, _episode} -> acc + 1
              {:error, _changeset} -> acc
            end
          end
        end
      end)

    {:ok, count}
  end

  ## Private Functions

  defp create_episodes_for_season(media_item, season, config) do
    alias Mydia.Metadata

    # Get provider ID - prefer tvdb_id for TV shows
    # Only use tvdb_season_id routing when we actually have a tvdb_id
    {provider_id, has_tvdb} =
      cond do
        media_item.tvdb_id ->
          {to_string(media_item.tvdb_id), true}

        media_item.tmdb_id ->
          {to_string(media_item.tmdb_id), false}

        true ->
          case media_item.metadata do
            %{"provider_id" => id} when is_binary(id) -> {id, false}
            _ -> {nil, false}
          end
      end

    # Pass tvdb_season_id only if we have a tvdb_id (otherwise season IDs are TMDB).
    # Thread the show's original language so episode selection can fall back to it
    # before English, matching the enricher path.
    original_language = Metadata.LanguageCode.original_language_from(media_item.metadata)

    fetch_opts =
      if has_tvdb do
        [
          tvdb_season_id: Map.get(season, :tvdb_season_id),
          original_language: original_language
        ]
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      else
        []
      end

    case Metadata.fetch_season_cached(
           config,
           to_string(provider_id),
           season.season_number,
           fetch_opts
         ) do
      {:ok, season_data} ->
        upsert_episodes_from_season(media_item, season_data,
          monitor_fn: fn season_num, air_date ->
            should_monitor_new_episode?(media_item, season_num, air_date)
          end
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_air_date(nil), do: nil
  defp parse_air_date(%Date{} = date), do: date

  defp parse_air_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_air_date(_), do: nil

  # Determines if a new episode should be monitored based on the media_item's monitoring preset.
  # This is used when creating new episodes during metadata refresh.
  def should_monitor_new_episode?(media_item, season_number, air_date) do
    # If the media_item itself isn't monitored, don't monitor episodes
    if media_item.monitored do
      preset = media_item.monitoring_preset || :all
      today = Date.utc_today()

      case preset do
        :all ->
          # Monitor all episodes except specials (season 0)
          season_number > 0

        :none ->
          false

        :future ->
          # Monitor if air_date is in the future or not set
          is_nil(air_date) || Date.compare(air_date, today) == :gt

        :missing ->
          # New episodes have no files, so always monitor
          # (unless it's a special)
          season_number > 0

        :existing ->
          # Only monitor episodes with files - new episodes have none
          false

        :first_season ->
          season_number == 1

        :latest_season ->
          # For new episodes, we need to determine if this is the latest season
          # Query existing episodes to find the current latest season
          latest_season = get_latest_season_number(media_item.id)
          # Monitor if this episode's season is >= the latest known season
          # This handles the case where a new season is being added
          season_number >= latest_season && season_number > 0
      end
    else
      false
    end
  end

  # Gets the highest season number for a media item
  defp get_latest_season_number(media_item_id) do
    Episode
    |> where([e], e.media_item_id == ^media_item_id)
    |> where([e], e.season_number > 0)
    |> select([e], max(e.season_number))
    |> Repo.one() || 1
  end

  defp apply_media_item_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:type, type}, query ->
        where(query, [m], m.type == ^type)

      {:monitored, monitored}, query ->
        where(query, [m], m.monitored == ^monitored)

      {:category, category}, query when is_atom(category) ->
        where(query, [m], m.category == ^to_string(category))

      {:category, category}, query when is_binary(category) ->
        where(query, [m], m.category == ^category)

      {:library_path_type, library_type}, query ->
        filter_by_library_path_type(query, library_type)

      {:search, search_term}, query when is_binary(search_term) ->
        search_pattern = "%#{String.downcase(search_term)}%"
        where(query, [m], like(fragment("lower(?)", m.title), ^search_pattern))

      {:added_since, datetime}, query ->
        where(query, [m], m.inserted_at >= ^datetime)

      {:limit, limit}, query when is_integer(limit) and limit > 0 ->
        limit(query, ^limit)

      {:order_by, field}, query when field in [:title, :year, :inserted_at] ->
        order_by(query, [m], asc: ^field)

      {:has_files, true}, query ->
        filter_by_has_files(query)

      _other, query ->
        query
    end)
  end

  # Filter media items to only those that have at least one media file.
  # Movies: direct media_file association via media_item_id
  # TV Shows: indirect via episodes that have media files
  defp filter_by_has_files(query) do
    movie_subquery =
      from mf in Mydia.Library.MediaFile,
        where: not is_nil(mf.media_item_id),
        select: mf.media_item_id,
        distinct: true

    episode_subquery =
      from mf in Mydia.Library.MediaFile,
        join: e in Episode,
        on: mf.episode_id == e.id,
        select: e.media_item_id,
        distinct: true

    where(
      query,
      [m],
      m.id in subquery(movie_subquery) or m.id in subquery(episode_subquery)
    )
  end

  # Filter media items by library path type using a subquery
  # This is more efficient than client-side filtering
  defp filter_by_library_path_type(query, library_type) do
    # Subquery to get media_item_ids from media_files in library paths of this type
    media_item_subquery =
      from mf in Mydia.Library.MediaFile,
        join: lp in Mydia.Settings.LibraryPath,
        on: mf.library_path_id == lp.id,
        where: lp.type == ^library_type and not is_nil(mf.media_item_id),
        select: mf.media_item_id,
        distinct: true

    # Subquery to get media_item_ids from episodes that have media files in library paths of this type
    episode_subquery =
      from mf in Mydia.Library.MediaFile,
        join: lp in Mydia.Settings.LibraryPath,
        on: mf.library_path_id == lp.id,
        join: e in Mydia.Media.Episode,
        on: mf.episode_id == e.id,
        where: lp.type == ^library_type,
        select: e.media_item_id,
        distinct: true

    # Combine both: direct media files and episode media files
    where(
      query,
      [m],
      m.id in subquery(media_item_subquery) or m.id in subquery(episode_subquery)
    )
  end

  defp apply_episode_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:season, season}, query ->
        where(query, [e], e.season_number == ^season)

      {:monitored, monitored}, query ->
        where(query, [e], e.monitored == ^monitored)

      _other, query ->
        query
    end)
  end

  # Helper function to check if a download is active
  # Downloads are active if they haven't completed and haven't failed
  defp download_active?(download) do
    is_nil(download.completed_at) && is_nil(download.error_message)
  end

  ## Category Classification

  @doc """
  Updates the category of a media item.

  ## Options
    - `:override` - If true, sets `category_override` flag to prevent auto-reclassification (default: false)

  ## Examples

      iex> update_category(media_item, :anime_movie)
      {:ok, %MediaItem{}}

      iex> update_category(media_item, :anime_movie, override: true)
      {:ok, %MediaItem{category: "anime_movie", category_override: true}}
  """
  @spec update_category(MediaItem.t(), atom() | String.t(), keyword()) ::
          {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t()}
  def update_category(%MediaItem{} = media_item, category, opts \\ []) do
    media_item
    |> MediaItem.category_changeset(category, opts)
    |> Repo.update()
  end

  @doc """
  Clears the category override flag, allowing auto-reclassification on metadata refresh.

  ## Examples

      iex> clear_category_override(media_item)
      {:ok, %MediaItem{category_override: false}}
  """
  @spec clear_category_override(MediaItem.t()) ::
          {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t()}
  def clear_category_override(%MediaItem{} = media_item) do
    media_item
    |> MediaItem.clear_category_override_changeset()
    |> Repo.update()
  end

  @doc """
  Re-classifies a media item based on its current metadata.

  If `category_override` is true, the category is not changed unless `force: true` is passed.

  ## Options
    - `:force` - If true, ignores the override flag and re-classifies anyway (default: false)

  ## Examples

      iex> reclassify_media_item(media_item)
      {:ok, %MediaItem{}}
  """
  @spec reclassify_media_item(MediaItem.t(), keyword()) ::
          {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t()}
  def reclassify_media_item(%MediaItem{} = media_item, opts \\ []) do
    force = Keyword.get(opts, :force, false)

    if media_item.category_override && !force do
      {:ok, media_item}
    else
      category = CategoryClassifier.classify(media_item)

      media_item
      |> MediaItem.category_changeset(category)
      |> Repo.update()
    end
  end

  @doc """
  Re-classifies all media items that don't have a category override.

  Useful for backfilling categories on existing media items.

  Returns `{:ok, count}` where count is the number of updated items.
  """
  @spec reclassify_all_media_items() :: {:ok, non_neg_integer()}
  def reclassify_all_media_items do
    MediaItem
    |> where([m], m.category_override == false or is_nil(m.category_override))
    |> Repo.all()
    |> Enum.reduce(0, fn media_item, count ->
      category = CategoryClassifier.classify(media_item)

      case update_category(media_item, category) do
        {:ok, _} -> count + 1
        {:error, _} -> count
      end
    end)
    |> then(&{:ok, &1})
  end

  @doc """
  Re-classifies multiple media items by their IDs.

  Returns a summary map with counts and details of what changed.

  ## Options
    - `:force` - If true, ignores category_override flags (default: false)

  ## Returns

      {:ok, %{
        total: 10,
        updated: 5,
        skipped: 3,
        unchanged: 2,
        details: [%{id: "...", old_category: "movie", new_category: "anime_movie", changed: true}, ...]
      }}
  """
  @spec reclassify_media_items([binary()], keyword()) :: {:ok, map()}
  def reclassify_media_items(ids, opts \\ []) when is_list(ids) do
    force = Keyword.get(opts, :force, false)

    media_items =
      MediaItem
      |> where([m], m.id in ^ids)
      |> Repo.all()

    results =
      Enum.map(media_items, fn media_item ->
        old_category = media_item.category
        new_category = CategoryClassifier.classify(media_item)

        cond do
          media_item.category_override && !force ->
            %{
              id: media_item.id,
              title: media_item.title,
              old_category: old_category,
              new_category: old_category,
              changed: false,
              skipped: true,
              reason: "category_override"
            }

          to_string(old_category) == to_string(new_category) ->
            %{
              id: media_item.id,
              title: media_item.title,
              old_category: old_category,
              new_category: to_string(new_category),
              changed: false,
              skipped: false,
              reason: nil
            }

          true ->
            case update_category(media_item, new_category) do
              {:ok, _updated} ->
                %{
                  id: media_item.id,
                  title: media_item.title,
                  old_category: old_category,
                  new_category: to_string(new_category),
                  changed: true,
                  skipped: false,
                  reason: nil
                }

              {:error, _} ->
                %{
                  id: media_item.id,
                  title: media_item.title,
                  old_category: old_category,
                  new_category: old_category,
                  changed: false,
                  skipped: true,
                  reason: "update_failed"
                }
            end
        end
      end)

    summary = %{
      total: length(results),
      updated: Enum.count(results, & &1.changed),
      skipped: Enum.count(results, & &1.skipped),
      unchanged: Enum.count(results, &(!&1.changed && !&1.skipped)),
      details: results
    }

    {:ok, summary}
  end

  @doc """
  Partitions selected media item ids into those needing an automatic release
  search and a count of those that do not need one.

  A movie needs a search when it has no untrashed media file and no occupying
  download (see `Mydia.Downloads.Download.occupying/1`). Monitored status is not
  part of the movie rule: `Mydia.Jobs.MovieSearch` in `"specific"` mode does not
  check it either, so an unmonitored movie is still searchable on request.

  A TV show needs a search when at least one of its episodes is monitored (show
  and episode), has aired, has no untrashed media file, and has no occupying
  download, excluding S00 specials unless `:monitor_special_episodes` is set.
  That is the same set `Mydia.Jobs.TVShowSearch` searches in `"show"` mode, so
  the caller's queued/skipped counts match what the job will actually do.

  Ids that no longer exist are counted in neither the returned list nor the
  skipped count, so a stale selection still reports truthful numbers.

  Returns `{items_needing_search, skipped_count}`.
  """
  @spec partition_for_auto_search([binary()]) :: {[MediaItem.t()], non_neg_integer()}
  def partition_for_auto_search([]), do: {[], 0}

  def partition_for_auto_search(ids) when is_list(ids) do
    items = movies_needing_search(ids) ++ shows_needing_search(ids)

    existing_count =
      MediaItem
      |> where([m], m.id in ^ids)
      |> Repo.aggregate(:count)

    {items, existing_count - length(items)}
  end

  defp movies_needing_search(ids) do
    MediaItem
    |> where([m], m.id in ^ids and m.type == "movie")
    |> where([m], m.id not in subquery(occupying_download_media_item_ids()))
    |> join(:left, [m], mf in Mydia.Library.MediaFile,
      on: mf.media_item_id == m.id and is_nil(mf.trashed_at)
    )
    |> group_by([m], m.id)
    |> having([_m, mf], count(mf.id) == 0)
    |> Repo.all()
  end

  defp occupying_download_media_item_ids do
    Mydia.Downloads.Download.occupying()
    |> where([d], not is_nil(d.media_item_id))
    |> select([d], d.media_item_id)
    |> distinct(true)
  end

  defp shows_needing_search(ids) do
    show_ids =
      Episode
      |> join(:inner, [e], m in assoc(e, :media_item))
      |> where([e, m], e.media_item_id in ^ids and m.type == "tv_show")
      |> where([e, m], e.monitored == true and m.monitored == true)
      |> where([e], e.air_date <= ^Date.utc_today())
      |> exclude_special_episodes()
      |> where([e], e.id not in subquery(occupying_download_episode_ids()))
      |> join(:left, [e], mf in Mydia.Library.MediaFile,
        on: mf.episode_id == e.id and is_nil(mf.trashed_at)
      )
      |> group_by([e], e.id)
      |> having([_e, _m, mf], count(mf.id) == 0)
      |> select([e], e.media_item_id)
      |> distinct(true)
      |> Repo.all()

    MediaItem
    |> where([m], m.id in ^show_ids)
    |> Repo.all()
  end

  defp exclude_special_episodes(query) do
    if monitor_special_episodes?() do
      query
    else
      where(query, [e], e.season_number != 0)
    end
  end

  defp monitor_special_episodes? do
    :mydia
    |> Application.get_env(:episode_monitor, [])
    |> Keyword.get(:monitor_special_episodes, false)
  end

  defp occupying_download_episode_ids do
    Mydia.Downloads.Download.occupying()
    |> where([d], not is_nil(d.episode_id))
    |> select([d], d.episode_id)
    |> distinct(true)
  end

  # Auto-classify a newly created media item
  defp auto_classify_media_item(%MediaItem{} = media_item) do
    category = CategoryClassifier.classify(media_item)

    case media_item
         |> MediaItem.category_changeset(category)
         |> Repo.update() do
      {:ok, updated_item} -> updated_item
      {:error, _} -> media_item
    end
  end

  # Attempts to discover a TVDB ID for a TV show that only has a TMDB ID.
  # On success, updates the media item and switches to the TVDB provider.
  # On failure, returns the original TMDB provider info unchanged.
  defp maybe_discover_tvdb_id(%MediaItem{} = media_item, tmdb_provider_id, config) do
    Logger.info("Attempting TVDB discovery for TMDB-only TV show",
      media_item_id: media_item.id,
      title: media_item.title,
      tmdb_id: media_item.tmdb_id
    )

    case do_recover_provider_id_by_title(media_item, :tv_show, config) do
      {:ok, recovered_id, updated_item} when not is_nil(updated_item.tvdb_id) ->
        Logger.info("Discovered TVDB ID for TV show",
          media_item_id: media_item.id,
          title: media_item.title,
          tvdb_id: updated_item.tvdb_id
        )

        {to_string(recovered_id), :tvdb, updated_item}

      _ ->
        # Discovery failed or didn't find a TVDB match — keep using TMDB
        {tmdb_provider_id, :tmdb, media_item}
    end
  end

  @doc """
  Recover TMDB ID by searching for the media item by title.

  This is useful when a media item was created without a provider ID (e.g., due to a bug)
  and needs to have its ID recovered via a title search.

  For TV shows, searches TVDB and stores tvdb_id. For movies, searches TMDB and stores tmdb_id.

  Returns {:ok, provider_id, updated_media_item} or {:error, reason}
  """
  @spec recover_provider_id_by_title(MediaItem.t(), atom()) ::
          {:ok, integer(), MediaItem.t()} | {:error, term()}
  def recover_provider_id_by_title(%MediaItem{} = media_item, media_type) do
    alias Mydia.Metadata
    config = Metadata.default_relay_config()
    do_recover_provider_id_by_title(media_item, media_type, config)
  end

  defp do_recover_provider_id_by_title(%MediaItem{} = media_item, media_type, config) do
    alias Mydia.Metadata

    Logger.info("Attempting to recover provider ID by title search",
      media_item_id: media_item.id,
      title: media_item.title,
      media_type: media_type
    )

    search_opts =
      if media_item.year do
        [media_type: media_type, year: media_item.year]
      else
        [media_type: media_type]
      end

    case Metadata.search(config, media_item.title, search_opts) do
      {:ok, []} ->
        # Retry without year if no results
        if media_item.year do
          case Metadata.search(config, media_item.title, media_type: media_type) do
            {:ok, results} when results != [] ->
              select_and_update_provider_id(results, media_item, media_type)

            _ ->
              {:error, :no_matches_found}
          end
        else
          {:error, :no_matches_found}
        end

      {:ok, results} ->
        select_and_update_provider_id(results, media_item, media_type)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp select_and_update_provider_id(results, media_item, media_type) do
    alias Mydia.Metadata.Structs.SearchResult

    # Score and select best match
    scored_results =
      Enum.map(results, fn result ->
        score = calculate_title_match_score(result, media_item)
        {result, score}
      end)

    case Enum.max_by(scored_results, fn {_result, score} -> score end, fn -> nil end) do
      {%SearchResult{provider_id: provider_id, provider: provider}, score} when score >= 0.5 ->
        case Integer.parse(provider_id) do
          {parsed_id, ""} ->
            # For TV shows from TVDB, store as tvdb_id; otherwise store as tmdb_id
            {id_field, update_attrs} =
              if media_type == :tv_show and provider == :tvdb do
                {:tvdb_id, %{tvdb_id: parsed_id}}
              else
                {:tmdb_id, %{tmdb_id: parsed_id}}
              end

            Logger.info("Recovered provider ID via title search",
              media_item_id: media_item.id,
              title: media_item.title,
              id_field: id_field,
              provider_id: parsed_id,
              match_score: score
            )

            # Update the media item with the recovered ID
            case update_media_item(media_item, update_attrs, reason: "Provider ID recovered") do
              {:ok, updated_item} ->
                {:ok, parsed_id, updated_item}

              {:error, _changeset} ->
                # Even if update fails, return the ID so refresh can proceed
                {:ok, parsed_id, media_item}
            end

          _ ->
            {:error, :invalid_provider_id}
        end

      _ ->
        {:error, :no_confident_match}
    end
  end

  def calculate_title_match_score(result, media_item) do
    base_score = 0.5
    title_sim = title_similarity(result.title, media_item.title)

    score =
      base_score +
        title_sim * 0.25 +
        if(year_matches?(result.year, media_item.year), do: 0.15, else: 0.0) +
        if(exact_title_match?(result.title, media_item.title), do: 0.15, else: 0.0) +
        title_derivative_penalty(result.title, media_item.title)

    min(score, 1.0)
  end

  defp title_similarity(title1, title2) when is_binary(title1) and is_binary(title2) do
    norm1 = normalize_title(title1)
    norm2 = normalize_title(title2)

    cond do
      norm1 == norm2 -> 1.0
      String.contains?(norm1, norm2) or String.contains?(norm2, norm1) -> 0.8
      true -> String.jaro_distance(norm1, norm2)
    end
  end

  defp title_similarity(_title1, _title2), do: 0.0

  defp normalize_title(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^\w\s]/, "")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  def exact_title_match?(result_title, search_title)
      when is_binary(result_title) and is_binary(search_title) do
    normalize_title(result_title) == normalize_title(search_title)
  end

  def exact_title_match?(_result_title, _search_title), do: false

  defp title_derivative_penalty(result_title, search_title)
       when is_binary(result_title) and is_binary(search_title) do
    norm_result = String.downcase(result_title) |> String.trim()
    norm_search = String.downcase(search_title) |> String.trim()

    if norm_result != norm_search and String.contains?(norm_result, norm_search) do
      search_len = String.length(norm_search)
      result_len = String.length(norm_result)
      extra_ratio = (result_len - search_len) / result_len
      -extra_ratio * 0.15
    else
      0.0
    end
  end

  defp title_derivative_penalty(_result_title, _search_title), do: 0.0

  def year_matches?(result_year, nil), do: result_year != nil
  def year_matches?(nil, _media_year), do: false

  def year_matches?(result_year, media_year) when is_integer(result_year) do
    abs(result_year - media_year) <= 1
  end

  def year_matches?(_result_year, _media_year), do: false

  # Determines if we should skip refreshing season data based on the last refresh time
  defp should_skip_season_refresh?(%MediaItem{seasons_refreshed_at: nil}), do: false

  defp should_skip_season_refresh?(%MediaItem{} = media_item) do
    config = Mydia.Config.get()

    # Determine if show is completed/ended
    is_completed =
      case media_item.metadata do
        %{"status" => status} when is_binary(status) ->
          String.downcase(status) in ["ended", "canceled", "cancelled"]

        _ ->
          false
      end

    # Get appropriate threshold based on show status
    threshold_hours =
      if is_completed do
        config.media.completed_show_refresh_threshold_hours
      else
        config.media.season_refresh_threshold_hours
      end

    # Check if enough time has passed since last refresh
    now = DateTime.utc_now()
    threshold_seconds = threshold_hours * 3600
    diff = DateTime.diff(now, media_item.seasons_refreshed_at, :second)

    diff < threshold_seconds
  end

  ## Favorites (delegated to Collections context)
  ##
  ## These functions now delegate to the Collections context which uses the
  ## unified collection system. The user_favorites table is deprecated.

  @doc """
  Checks if a media item is favorited by a user.

  Delegates to Collections.is_favorite?/2.

  ## Examples

      iex> is_favorite?(user_id, media_item_id)
      true

      iex> is_favorite?(user_id, non_favorited_media_item_id)
      false

  """
  @spec is_favorite?(binary(), binary()) :: boolean()
  def is_favorite?(user_id, media_item_id) do
    user = Mydia.Accounts.get_user!(user_id)
    Mydia.Collections.is_favorite?(user, media_item_id)
  end

  @doc """
  Toggles favorite status for a media item.

  Delegates to Collections.toggle_favorite/2.

  Returns {:ok, :added} or {:ok, :removed} on success.

  ## Examples

      iex> toggle_favorite(user_id, media_item_id)
      {:ok, :added}

      iex> toggle_favorite(user_id, media_item_id)
      {:ok, :removed}

  """
  @spec toggle_favorite(binary(), binary()) :: {:ok, :added | :removed} | {:error, term()}
  def toggle_favorite(user_id, media_item_id) do
    user = Mydia.Accounts.get_user!(user_id)
    Mydia.Collections.toggle_favorite(user, media_item_id)
  end

  @doc """
  Lists all favorite media items for a user.

  Delegates to Collections context and returns the media items from
  the user's Favorites collection.

  ## Options
    - `:preload` - List of associations to preload on media_items

  ## Examples

      iex> list_user_favorites(user_id)
      [%MediaItem{}, ...]

      iex> list_user_favorites(user_id, preload: [:media_files])
      [%MediaItem{media_files: [...]}, ...]

  """
  @spec list_user_favorites(binary(), keyword()) :: [MediaItem.t()]
  def list_user_favorites(user_id, opts \\ []) do
    user = Mydia.Accounts.get_user!(user_id)

    case Mydia.Collections.get_or_create_favorites(user) do
      {:ok, favorites} ->
        Mydia.Collections.list_collection_items(favorites, opts)

      {:error, _} ->
        []
    end
  end
end
