defmodule Mydia.Media do
  @moduledoc """
  The Media context handles movies, TV shows, and episodes.
  """

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  require Logger
  alias Mydia.Repo
  alias Mydia.Accounts.Scope
  alias Mydia.Media.{AvailabilityStatus, MediaItem, Episode, CategoryClassifier}
  alias Mydia.Media.ContentRating
  alias Mydia.Media.Restrictions
  alias Mydia.Media.Structs.CalendarEntry
  alias Mydia.Metadata.Access, as: MetadataAccess
  alias Mydia.Events

  ## Media Items

  @doc """
  Returns the list of media items.

  ## Options
    - `:type` - Filter by type ("movie" or "tv_show")
    - `:ids` - Filter to a specific list of media item ids
    - `:monitored` - Filter by monitored status (true/false)
    - `:category` - Filter by category (atom or string, e.g., :anime_movie or "anime_movie")
    - `:library_path_type` - Filter by library path type (:movies, :series, etc.)
    - `:search` - Search by title (case-insensitive substring match)
    - `:added_since` - Filter to items inserted after this DateTime
    - `:limit` - Maximum number of items to return
    - `:order_by` - Field to order by (:title, :year, or :inserted_at)
    - `:preload` - List of associations to preload
  """
  @spec list_media_items(Scope.t(), keyword()) :: [MediaItem.t()]
  def list_media_items(%Scope{} = scope, opts \\ []) do
    MediaItem
    |> Restrictions.apply(scope)
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
  @spec get_media_item!(Scope.t(), binary(), keyword()) :: MediaItem.t()
  def get_media_item!(%Scope{} = scope, id, opts \\ []) do
    MediaItem
    |> Restrictions.apply(scope)
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
  @spec list_items_page(Scope.t(), keyword()) :: [MediaItem.t()]
  def list_items_page(%Scope{} = scope, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    since = Keyword.get(opts, :updated_since)
    after_cursor = Keyword.get(opts, :after)

    query =
      MediaItem
      |> Restrictions.apply(scope)
      |> then(&from(m in &1, order_by: [asc: m.updated_at, asc: m.id], limit: ^limit))

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
  Pages media items with an ownership flag, for the plugin `library_item`
  namespace.

  Options and cursor semantics are exactly `list_items_page/1`'s — this
  delegates to it rather than restating the keyset, so the two namespaces can
  never drift. Ownership is resolved in a second pass over the returned page:
  a movie is owned when it has an untrashed `media_files` row, a show when any
  of its episodes does.

  Two extra queries per page, both plain `IN` filters, so the whole thing stays
  portable across SQLite and PostgreSQL.
  """
  @spec list_library_items_page(Scope.t(), keyword()) :: [map()]
  def list_library_items_page(%Scope{} = scope, opts \\ []) do
    items = list_items_page(scope, opts)
    owned = owned_media_item_ids(Enum.map(items, & &1.id))

    Enum.map(items, fn item ->
      %{
        id: item.id,
        type: item.type,
        title: item.title,
        year: item.year,
        tmdb_id: item.tmdb_id,
        tvdb_id: item.tvdb_id,
        imdb_id: item.imdb_id,
        updated_at: item.updated_at,
        owned: MapSet.member?(owned, item.id)
      }
    end)
  end

  defp owned_media_item_ids([]), do: MapSet.new()

  defp owned_media_item_ids(ids) do
    direct =
      Repo.all(
        from(f in Mydia.Library.MediaFile,
          where: is_nil(f.trashed_at) and f.media_item_id in ^ids,
          select: f.media_item_id
        )
      )

    via_episodes =
      Repo.all(
        from(f in Mydia.Library.MediaFile,
          join: e in Mydia.Media.Episode,
          on: e.id == f.episode_id,
          where: is_nil(f.trashed_at) and e.media_item_id in ^ids,
          select: e.media_item_id
        )
      )

    MapSet.new(direct ++ via_episodes)
  end

  @doc """
  Gets a single media item by TMDB ID.
  """
  @spec get_media_item_by_tmdb(Scope.t(), integer(), keyword()) :: MediaItem.t() | nil
  def get_media_item_by_tmdb(%Scope{} = scope, tmdb_id, opts \\ []) do
    MediaItem
    |> Restrictions.apply(scope)
    |> where([m], m.tmdb_id == ^tmdb_id)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Gets a single media item by TVDB ID.
  """
  @spec get_media_item_by_tvdb(Scope.t(), integer(), keyword()) :: MediaItem.t() | nil
  def get_media_item_by_tvdb(%Scope{} = scope, tvdb_id, opts \\ []) do
    MediaItem
    |> Restrictions.apply(scope)
    |> where([m], m.tvdb_id == ^tvdb_id)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Finds a media item by external IDs using cascading lookup: IMDB → TVDB → TMDB.

  Accepts a map with atom keys: `%{imdb: id, tvdb: id, tmdb: id}`.

  The cascade advances on a lookup *miss*, not on a missing id. Branching on
  mere presence is what left every Plex episode unmapped: Plex supplies an imdb
  id for every show, while Mydia stores tvdb and tmdb for shows and no imdb at
  all, so the imdb branch was always taken and always missed.

  ## Options

    * `:type` - `"movie"` or `"tv_show"`. When set, a row of a different type is
      not a match and the cascade continues to the next id. Callers that address
      a movie or a show specifically should pass it. Callers that legitimately
      accept either, such as `Mydia.Plugins.Matcher.match_item/1`, should not.

  Returns nil if no match is found.
  """
  @spec find_by_external_ids(Scope.t(), map(), keyword()) :: MediaItem.t() | nil
  def find_by_external_ids(%Scope{} = scope, ids, opts \\ []) when is_map(ids) do
    type = Keyword.get(opts, :type)
    validate_external_id_type!(type)

    find_by_imdb(Map.get(ids, :imdb), type, scope) ||
      find_by_tvdb(Map.get(ids, :tvdb), type, scope) ||
      find_by_tmdb(Map.get(ids, :tmdb), type, scope)
  end

  # `nil` means "no filter" and is always valid. Anything else must be one of
  # MediaItem's own valid types. An unrecognised value such as `"tvshow"`
  # (missing the underscore) would otherwise silently make every lookup
  # return nil via a `where` clause that matches nothing, which reads exactly
  # like a total mapping failure rather than the typo it is.
  defp validate_external_id_type!(nil), do: :ok

  defp validate_external_id_type!(type) do
    if type in MediaItem.valid_types() do
      :ok
    else
      raise ArgumentError,
            "invalid :type #{inspect(type)} for find_by_external_ids/2, " <>
              "expected nil or one of #{inspect(MediaItem.valid_types())}"
    end
  end

  defp find_by_imdb(nil, _type, _scope), do: nil

  defp find_by_imdb(imdb, type, scope) do
    MediaItem
    |> Restrictions.apply(scope)
    |> where([m], m.imdb_id == ^imdb)
    |> external_id_match(type)
  end

  defp find_by_tvdb(nil, _type, _scope), do: nil

  defp find_by_tvdb(tvdb, type, scope) do
    case parse_external_id(tvdb) do
      nil ->
        nil

      id ->
        MediaItem
        |> Restrictions.apply(scope)
        |> where([m], m.tvdb_id == ^id)
        |> external_id_match(type)
    end
  end

  defp find_by_tmdb(nil, _type, _scope), do: nil

  defp find_by_tmdb(tmdb, type, scope) do
    case parse_external_id(tmdb) do
      nil ->
        nil

      id ->
        MediaItem
        |> Restrictions.apply(scope)
        |> where([m], m.tmdb_id == ^id)
        |> external_id_match(type)
    end
  end

  # tvdb_id and tmdb_id are :integer columns, so Ecto's query planner raises
  # Ecto.Query.CastError when an interpolated param cannot be cast, rather
  # than returning nil. The crawl feeds these columns raw provider strings --
  # whatever follows `tvdb://` in a Plex GUID, or a Jellyfin `ProviderIds`
  # value, passed through untouched -- so a malformed id must fail closed
  # here (returning nil so the cascade continues to the next id) instead of
  # raising inside Engine.do_refresh/4's bare Enum.each and aborting every
  # remaining item in the crawl.
  #
  # Integer.parse/1 is used deliberately over String.to_integer/1, which
  # raises on non-numeric input rather than returning an error value.
  # Trailing garbage is rejected outright: Integer.parse/1 returns
  # `{123, "abc"}` for "123abc", and that partial parse is not the same id as
  # 123, so anything left over after the digits is treated as a non-match.
  defp parse_external_id(id) when is_integer(id), do: id

  defp parse_external_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {value, ""} -> value
      _ -> nil
    end
  end

  defp parse_external_id(_id), do: nil

  # `limit(1)` rather than a bare `Repo.one/1`: imdb_id carries no unique index,
  # so a duplicate would raise Ecto.MultipleResultsError partway through a crawl
  # and abort every remaining item. `order_by` makes the pick among duplicates
  # deterministic (oldest first) rather than left to whatever order the
  # database happens to return, which on PostgreSQL is not guaranteed to be
  # insertion order -- and the crawl now repeats daily, so a nondeterministic
  # pick could flip the stored mapping between runs.
  defp external_id_match(query, nil),
    do: query |> order_by([m], asc: m.inserted_at) |> limit(1) |> Repo.one()

  defp external_id_match(query, type) do
    query
    |> where([m], m.type == ^type)
    |> order_by([m], asc: m.inserted_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Finds an episode by show ID, season number, and episode number.

  Returns nil if no match is found or if season/episode are not integers.
  """
  @spec find_episode(Scope.t(), binary(), integer(), integer()) :: Episode.t() | nil
  def find_episode(%Scope{} = scope, show_id, season_number, episode_number)
      when is_integer(season_number) and is_integer(episode_number) do
    Episode
    |> Restrictions.apply_to_episodes(scope)
    |> where([e], e.media_item_id == ^show_id)
    |> where([e], e.season_number == ^season_number)
    |> where([e], e.episode_number == ^episode_number)
    |> limit(1)
    |> Repo.one()
  end

  def find_episode(%Scope{}, _, _, _), do: nil

  # A restricted account must not be able to pull an out-of-bounds title into
  # the library directly and skip the approval gate. The item does not exist
  # yet, so its category comes from classifying the metadata it would be
  # created with, the same classifier that runs on insert.
  @doc """
  True when this scope may create or move an item into the state `attrs`
  describes. Public because `Mydia.MediaRequests` gates request creation on the
  same rule and must not restate it.
  """
  @spec writable?(Scope.t(), map()) :: boolean()
  def writable?(%Scope{allowed_categories: nil, max_content_age: nil}, _attrs), do: true

  def writable?(%Scope{} = scope, attrs) do
    metadata = Map.get(attrs, :metadata) || Map.get(attrs, "metadata")
    type = Map.get(attrs, :type) || Map.get(attrs, "type")

    candidate = %MediaItem{
      category: to_string(classify_for_write(type, metadata)),
      content_rating_age: ContentRating.min_age(content_rating_of(metadata))
    }

    Restrictions.visible?(candidate, scope)
  end

  # Callers want a tagged tuple to thread through `with`.
  defp authorize_write(scope, attrs) do
    if writable?(scope, attrs), do: :ok, else: {:error, :restricted}
  end

  defp classify_for_write("tv_show", metadata),
    do: CategoryClassifier.classify_from_metadata(:tv_show, metadata)

  defp classify_for_write(_type, metadata),
    do: CategoryClassifier.classify_from_metadata(:movie, metadata)

  defp content_rating_of(%{content_rating: rating}), do: rating
  defp content_rating_of(_metadata), do: nil

  # An update that does not mention metadata leaves the stored metadata in
  # place, so judging the attrs alone would classify the item as though it had
  # none and wrongly refuse an in-bounds edit.
  defp merged_write_attrs(%MediaItem{} = item, attrs) do
    %{
      type: Map.get(attrs, :type) || Map.get(attrs, "type") || item.type,
      metadata: Map.get(attrs, :metadata) || Map.get(attrs, "metadata") || item.metadata
    }
  end

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
    - `:config` - Metadata relay config forwarded to `refresh_episodes_for_tv_show/2`.
      Callers that inject a Bypass (or any non-default relay) must pass it here;
      otherwise the automatic refresh silently uses `Metadata.default_relay_config/0`.
  """
  @spec create_media_item(Scope.t(), map(), keyword()) ::
          {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t() | :restricted}
  def create_media_item(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    with :ok <- authorize_write(scope, attrs),
         {:ok, media_item} <-
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

        refresh_opts =
          [season_monitoring: season_monitoring]
          |> maybe_put_refresh_config(Keyword.get(opts, :config))

        case refresh_episodes_for_tv_show(media_item, refresh_opts) do
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

  defp maybe_put_refresh_config(opts, nil), do: opts
  defp maybe_put_refresh_config(opts, config), do: Keyword.put(opts, :config, config)

  @doc """
  Updates a media item.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
    - `:reason` - Description of what was updated (e.g., "Metadata refreshed") - defaults to "Updated"
  """
  @spec update_media_item(Scope.t(), MediaItem.t(), map(), keyword()) ::
          {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t() | :restricted}
  def update_media_item(%Scope{} = scope, %MediaItem{} = media_item, attrs, opts \\ []) do
    with :ok <- authorize_write(scope, merged_write_attrs(media_item, attrs)) do
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
  @spec delete_media_item(Scope.t(), MediaItem.t(), keyword()) ::
          {:ok, MediaItem.t(), non_neg_integer()} | {:error, Ecto.Changeset.t()}
  def delete_media_item(%Scope{} = _scope, %MediaItem{} = media_item, opts \\ []) do
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
  @spec update_media_items_monitored(Scope.t(), [binary()], boolean(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def update_media_items_monitored(%Scope{} = _scope, ids, monitored, opts \\ [])
      when is_list(ids) do
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
  @spec update_media_items_batch(Scope.t(), [binary()], map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def update_media_items_batch(%Scope{} = _scope, ids, attrs)
      when is_list(ids) and is_map(attrs) do
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
  @spec delete_media_items(Scope.t(), [binary()], keyword()) ::
          {:ok, non_neg_integer(), non_neg_integer()} | {:error, term()}
  def delete_media_items(%Scope{} = _scope, ids, opts \\ []) when is_list(ids) do
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
  @spec count_movies(Scope.t()) :: non_neg_integer()
  def count_movies(%Scope{} = scope) do
    MediaItem
    |> Restrictions.apply(scope)
    |> where([m], m.type == "movie")
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the count of TV shows in the library.
  """
  @spec count_tv_shows(Scope.t()) :: non_neg_integer()
  def count_tv_shows(%Scope{} = scope) do
    MediaItem
    |> Restrictions.apply(scope)
    |> where([m], m.type == "tv_show")
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
  @spec get_library_status_map(Scope.t()) :: map()
  def get_library_status_map(%Scope{} = scope) do
    MediaItem
    |> Restrictions.apply(scope)
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

  @doc """
  Returns library status for a specific set of TMDB ids, scoped to one type.

  Same value shape as `get_library_status_map/0`, but scoped to the ids asked
  for. Use this when checking a handful of ids (a franchise's members, TMDB
  recommendations for a title) rather than loading the whole library.

  `type` is required and must be `"movie"` or `"tv_show"` — the caller already
  knows which, since a title's franchise members and recommendations are
  always its own type. A row of the other type that happens to share a TMDB id
  is not a match.

  ## Examples

      iex> library_status_for_tmdb_ids([671, 672], "movie")
      %{671 => %{in_library: true, monitored: true, type: "movie", id: "..."}}
  """
  @spec library_status_for_tmdb_ids(Scope.t(), [integer()], String.t()) :: map()
  def library_status_for_tmdb_ids(%Scope{}, [], _type), do: %{}

  def library_status_for_tmdb_ids(%Scope{} = scope, tmdb_ids, type)
      when is_list(tmdb_ids) and is_binary(type) do
    MediaItem
    |> Restrictions.apply(scope)
    |> where([m], m.type == ^type and m.tmdb_id in ^tmdb_ids)
    |> select([m], {m.tmdb_id, m.monitored, m.type, m.id})
    |> Repo.all()
    |> Map.new(fn {tmdb_id, monitored, type, id} ->
      {tmdb_id, %{in_library: true, monitored: monitored, type: type, id: id}}
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
  @spec list_episodes(Scope.t(), binary(), keyword()) :: [Episode.t()]
  def list_episodes(%Scope{} = scope, media_item_id, opts \\ []) do
    Episode
    |> Restrictions.apply_to_episodes(scope)
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
  @spec get_episode!(Scope.t(), binary(), keyword()) :: Episode.t()
  def get_episode!(%Scope{} = scope, id, opts \\ []) do
    Episode
    |> Restrictions.apply_to_episodes(scope)
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a single episode by media item ID, season, and episode number.
  """
  @spec get_episode_by_number(Scope.t(), binary(), integer(), integer(), keyword()) ::
          Episode.t() | nil
  def get_episode_by_number(
        %Scope{} = scope,
        media_item_id,
        season_number,
        episode_number,
        opts \\ []
      ) do
    Episode
    |> Restrictions.apply_to_episodes(scope)
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
  @spec get_next_episode(Scope.t(), Episode.t(), keyword()) :: Episode.t() | nil
  def get_next_episode(%Scope{} = scope, %Episode{} = episode, opts \\ []) do
    # Try to get next episode in same season first
    next_in_season =
      Episode
      |> Restrictions.apply_to_episodes(scope)
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
        |> Restrictions.apply_to_episodes(scope)
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

  # :existing is not redundant with the Upgrades sweep, it is what enables it:
  # `Mydia.Upgrades` only considers episodes with `monitored == true`, so this
  # is the one way to say "upgrade the files I have, stop chasing the ones I
  # never found". :first_season and :latest_season are gone because the season
  # header toggle does each in one click.
  @monitoring_presets [:all, :missing, :existing, :future, :none]

  @doc """
  Returns the list of valid monitoring presets.
  """
  @spec monitoring_presets() :: [atom()]
  def monitoring_presets, do: @monitoring_presets

  @doc """
  Reads the current episode rows back as whichever preset describes them, or
  `:custom` when none does.

  Derived rather than stored on purpose. Storing the last preset applied is
  what made the old label go stale the moment someone toggled a season by
  hand, since nothing wrote it back. Computing it from the rows means the
  label is either true or says `:custom`.

  Episodes must have `media_files` preloaded, which the show page already does.
  """
  @spec derive_monitoring_preset([Episode.t()]) :: atom()
  def derive_monitoring_preset([]), do: :none

  def derive_monitoring_preset(episodes) do
    monitored = MapSet.new(Enum.filter(episodes, & &1.monitored), & &1.id)

    # Nothing monitored is :none, decided before the search rather than during
    # it. Several partitions can produce the empty set (:future on a show whose
    # episodes have all aired, :existing on a show with no files), so a
    # first-match walk would answer "Future Episodes" for a show the user just
    # set to "No Episodes".
    if MapSet.size(monitored) == 0 do
      :none
    else
      Enum.find(@monitoring_presets, :custom, fn preset ->
        {to_monitor, _} = partition_episodes_by_preset(episodes, preset)
        MapSet.new(to_monitor, & &1.id) == monitored
      end)
    end
  end

  @doc """
  Applies a monitoring preset to the episodes of a TV show.

  A one-shot bulk rewrite of `episodes.monitored`, and nothing else. The show
  row is untouched, because the preset describes an action taken once rather
  than a standing rule. What happens to episodes discovered later is decided by
  `should_monitor_new_episode?/2`, reading the season they land in and, for a
  season that does not exist yet, `monitor_new_seasons`.

  ## Presets

  All of them exclude season 0; specials are opt-in.

  - `:all` - Every episode
  - `:missing` - Episodes without files, or not yet aired
  - `:existing` - Only episodes that have files, which is what leaves the
    Upgrades sweep something to work on without searching for what is absent
  - `:future` - Only episodes that have not aired
  - `:none` - Nothing

  ## Returns

  - `{:ok, count}` - Number of episodes whose monitored flag was written
  - `{:error, reason}`

  ## Examples

      iex> apply_episode_monitoring(media_item, :all)
      {:ok, 24}
  """
  @spec apply_episode_monitoring(MediaItem.t(), atom()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def apply_episode_monitoring(%MediaItem{type: "tv_show"} = media_item, preset)
      when preset in @monitoring_presets do
    Repo.transaction(fn ->
      episodes = list_episodes(Scope.system(), media_item.id, preload: [:media_files])
      {to_monitor, to_unmonitor} = partition_episodes_by_preset(episodes, preset)

      written =
        set_episodes_monitored(to_monitor, true) + set_episodes_monitored(to_unmonitor, false)

      Events.media_item_updated(
        media_item,
        :user,
        "media_context",
        "Applied '#{preset}' monitoring to episodes"
      )

      written
    end)
  end

  def apply_episode_monitoring(%MediaItem{type: type}, preset)
      when preset in @monitoring_presets do
    {:error, {:invalid_type, "apply_episode_monitoring only works for TV shows, got #{type}"}}
  end

  def apply_episode_monitoring(_media_item, preset) when preset not in @monitoring_presets do
    {:error, {:invalid_preset, "Unknown preset: #{preset}"}}
  end

  # Both branches of the bulk apply wrote the same update_all with a different
  # boolean, so it lives in one place.
  defp set_episodes_monitored([], _monitored), do: 0

  defp set_episodes_monitored(episodes, monitored) do
    ids = Enum.map(episodes, & &1.id)

    Episode
    |> where([e], e.id in ^ids)
    |> Repo.update_all(set: [monitored: monitored, updated_at: DateTime.utc_now()])
    |> elem(0)
  end

  @doc """
  Sets whether seasons that do not exist yet arrive monitored.

  Deliberately independent of the presets. Inferring it from the preset made
  two states unreachable: "monitor everything I have but do not chase new
  seasons", and setting the flag at all without a bulk rewrite that destroys
  hand-curated per-season monitoring. It also let a preset contradict itself,
  since :future unmonitors every aired episode while implying new seasons are
  wanted.
  """
  @spec set_monitor_new_seasons(MediaItem.t(), :all | :none) ::
          {:ok, MediaItem.t()} | {:error, term()}
  def set_monitor_new_seasons(%MediaItem{} = media_item, mode) when mode in [:all, :none] do
    # update_all rather than a changeset: the caller's struct may be stale, and
    # a changeset whose value matches the stale struct produces no change, so
    # the write would silently skip while the row still held the old value.
    MediaItem
    |> where([m], m.id == ^media_item.id)
    |> Repo.update_all(set: [monitor_new_seasons: mode, updated_at: DateTime.utc_now()])

    updated = get_media_item!(Scope.system(), media_item.id)

    Events.media_item_updated(
      updated,
      :user,
      "media_context",
      "New season monitoring set to #{mode}"
    )

    {:ok, updated}
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

  # Every preset below excludes season 0. Specials are opt-in through the
  # season header or the per-episode toggle, never swept in by a bulk action.
  # Without this guard :missing monitored fileless specials, which then left
  # `should_monitor_new_episode?/2` admitting every future special forever,
  # because its season-0 guard only covers the empty-season branch.
  defp partition_episodes_by_preset(episodes, :future) do
    today = Date.utc_today()

    Enum.split_with(episodes, fn ep ->
      ep.season_number > 0 && ep.air_date && Date.compare(ep.air_date, today) == :gt
    end)
  end

  defp partition_episodes_by_preset(episodes, :missing) do
    today = Date.utc_today()

    Enum.split_with(episodes, fn ep ->
      has_no_files = Enum.empty?(ep.media_files)
      is_future = ep.air_date && Date.compare(ep.air_date, today) == :gt
      ep.season_number > 0 && (has_no_files || is_future)
    end)
  end

  defp partition_episodes_by_preset(episodes, :existing) do
    Enum.split_with(episodes, fn ep ->
      ep.season_number > 0 && not Enum.empty?(ep.media_files)
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
  Gets the aggregate availability of a media item, independent of monitoring.

  Returns an `AvailabilityStatus` whose `state` describes what is on disk and whose
  `monitored` field describes whether anything is actively being pursued. The two are
  deliberately separate: an unmonitored movie with no file is `:missing` with
  `monitored: false`, not hidden behind a `:not_monitored` state.

  For series, episodes are classified over the monitored episodes when there are any,
  and over every episode when there are none, so the counts always have a meaningful
  denominator.

  ## Examples

      iex> get_media_status(%MediaItem{type: "movie", monitored: false, media_files: [], downloads: []})
      %AvailabilityStatus{state: :missing, monitored: false, file_count: 0}
  """
  @spec get_media_status(MediaItem.t()) :: AvailabilityStatus.t()
  def get_media_status(%MediaItem{type: "movie"} = media_item) do
    has_files = media_item.media_files != []
    has_downloads = Enum.any?(media_item.downloads, &download_active?/1)

    state =
      cond do
        has_files -> :downloaded
        has_downloads -> :downloading
        true -> :missing
      end

    %AvailabilityStatus{
      state: state,
      monitored: media_item.monitored,
      file_count: length(media_item.media_files)
    }
  end

  def get_media_status(%MediaItem{type: "tv_show", episodes: episodes} = media_item) do
    monitored_episodes = Enum.filter(episodes, & &1.monitored)

    # With nothing monitored there is no meaningful denominator, so fall back to every
    # episode. That keeps the x/y counts readable instead of rendering 0/0.
    scope = if monitored_episodes == [], do: episodes, else: monitored_episodes

    total = length(scope)
    downloaded_count = Enum.count(scope, fn ep -> ep.media_files != [] end)

    has_active_downloads =
      Enum.any?(scope, fn ep -> Enum.any?(ep.downloads, &download_active?/1) end)

    all_upcoming =
      scope != [] and
        Enum.all?(scope, fn ep ->
          ep.air_date && Date.compare(ep.air_date, Date.utc_today()) == :gt
        end)

    state =
      cond do
        total > 0 and downloaded_count == total -> :downloaded
        has_active_downloads -> :downloading
        all_upcoming -> :upcoming
        downloaded_count > 0 -> :partial
        true -> :missing
      end

    %AvailabilityStatus{
      state: state,
      # A monitored show with every episode unmonitored is not chasing anything, so it
      # renders muted rather than claiming a pursuit that will never happen. A show with
      # no episodes at all is a different case: nothing contradicts the show's own flag
      # yet, so a freshly added show awaiting metadata stays un-muted.
      monitored: media_item.monitored and (episodes == [] or monitored_episodes != []),
      downloaded: downloaded_count,
      total: total
    }
  end

  @doc """
  Re-fetches metadata from the provider and updates the media item.

  Delegates to `Mydia.Media.Refresh.run/2`, which owns provider resolution,
  the attribute writes, episode refresh and NFO regeneration.

  The second argument is a bare config map rather than a keyword list, for
  backwards compatibility with existing callers.

  ## Returns
    - `{:ok, media_item}` - Updated media item
    - `{:error, reason}` - Error reason
  """
  @spec refresh_metadata(MediaItem.t(), map() | nil) ::
          {:ok, MediaItem.t()} | {:error, term()}
  def refresh_metadata(%MediaItem{} = media_item, config \\ nil) do
    Mydia.Media.Refresh.run(media_item, config: config)
  end

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
      - `:config` - Metadata relay config. Defaults to `Metadata.default_relay_config/0`.
        Callers that inject a Bypass (or any non-default relay) must pass it;
        otherwise the refresh silently uses the global default.
      - `:force` - Fetch even when `seasons_refreshed_at` is inside the throttle
        window. Defaults to `false`. Pass it whenever a person asked for this
        show specifically; leave it off for sweeps. See
        `should_skip_season_refresh?/1`.

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
    # Honour an injected relay config (Bypass in tests, or a caller-specific
    # relay). Ignoring opts[:config] silently falls back to the global default
    # and was the root of the MediaAddHelpers CI timeout flake: the Bypass
    # stubs covered the add-path fetch, then create_media_item refreshed
    # against the real relay with Task.async_stream timeout: :infinity.
    config = Keyword.get(opts, :config) || Metadata.default_relay_config()

    # Resolve the provider to fetch from. `metadata_source` (when set) is the
    # authoritative provenance; only fall back to the legacy TVDB-precedence
    # rule and the stored metadata provider_id when it is absent.
    # Refresh.resolve_provider/1 already includes the stored-metadata fallback,
    # reading struct fields rather than string keys. (The old fallback here
    # matched %{"provider_id" => id} against an atom-keyed %MediaMetadata{} and
    # could never fire.) It returns an integer id; this function threads
    # provider ids as strings.
    {provider_id, provider_source} =
      case Mydia.Media.Refresh.resolve_provider(media_item) do
        {nil, nil} -> {nil, nil}
        {id, source} -> {to_string(id), source}
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
      if not Keyword.get(opts, :force, false) and should_skip_season_refresh?(media_item) do
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
        # `season_order` selects which of TVDB's parallel orderings the seasons
        # list describes. Without it the column is inert: a show switched to the
        # DVD ordering would refetch the official one and drift straight back to
        # a single 170-episode season. nil resolves to "official" inside
        # SeasonOrder.tvdb_type/1, so passing it through unguarded is correct.
        case Metadata.fetch_by_id(config, provider_id,
               media_type: :tv_show,
               provider: provider_source,
               season_order: media_item.season_order
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

            # Fetch and create episodes for each season. Track failures: the
            # timestamp below throttles the next refresh, so stamping it after a
            # partial pass would hide the seasons that failed until the
            # threshold expires.
            {episode_count, failed_seasons} =
              Enum.reduce_while(seasons_to_fetch, {0, 0}, fn season, {count, failed} ->
                # Skip season 0 (specials) unless explicitly monitoring all
                if season.season_number == 0 and season_monitoring != "all" do
                  {:cont, {count, failed}}
                else
                  Logger.info("Processing episodes for season #{season.season_number}")

                  case create_episodes_for_season(media_item, season, config) do
                    {:ok, created} ->
                      Logger.info(
                        "Processed #{created} episodes for season #{season.season_number}"
                      )

                      {:cont, {count + created, failed}}

                    # An ordering switch or a provider switch landed while this
                    # pass was fetching. Every season still to come was fetched
                    # against the same now-stale show, so stop rather than log
                    # one error per remaining season. Counting it as a failure
                    # is what leaves `seasons_refreshed_at` unstamped, which is
                    # what makes the next refresh re-fetch against the show as
                    # it actually is now.
                    {:error, :refresh_target_changed} ->
                      Logger.warning(
                        "Aborting season refresh: show changed mid-refresh",
                        media_item_id: media_item.id
                      )

                      {:halt, {count, failed + 1}}

                    {:error, reason} ->
                      Logger.error(
                        "Failed to create episodes for season #{season.season_number}: #{inspect(reason)}"
                      )

                      {:cont, {count, failed + 1}}
                  end
                end
              end)

            Logger.info("Total episodes processed: #{episode_count}")

            # The timestamp means "every season is current", so only a clean pass
            # over the *full* season set may stamp it. "first"/"latest"/"none"
            # come from the add-media UI and fetch a subset; stamping after one
            # would throttle the next "all" pass and leave the seasons it never
            # fetched stale until the threshold expired.
            cond do
              season_monitoring != "all" ->
                Logger.info(
                  "Not stamping seasons_refreshed_at: partial season selection " <>
                    "(#{season_monitoring})",
                  media_item_id: media_item.id
                )

              failed_seasons > 0 ->
                Logger.warning(
                  "Not stamping seasons_refreshed_at: #{failed_seasons} season(s) failed",
                  media_item_id: media_item.id
                )

              true ->
                stamp_seasons_refreshed(media_item)
            end

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

  @doc """
  Records that a show's seasons were successfully refreshed.

  Writes straight to the column rather than through `changeset/2`, matching
  `Upgrades.stamp_checked/2`. This field is owned by the refresh machinery and
  gates `should_skip_season_refresh?/1`, so it must not be mass-assignable from
  attrs a caller controls. Routing it through `update_media_item/3` is what
  silently dropped every write before, since `changeset/2` does not cast it.
  """
  @spec stamp_seasons_refreshed(MediaItem.t()) :: {non_neg_integer(), nil}
  def stamp_seasons_refreshed(%MediaItem{id: id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    MediaItem
    |> where([m], m.id == ^id)
    |> Repo.update_all(set: [seasons_refreshed_at: now])
  end

  ## Calendar

  @doc """
  Returns episodes with air dates in the specified date range.
  Only returns episodes for monitored media items by default.

  ## Options
    - `:preload` - List of associations to preload
    - `:monitored` - Filter by media item monitored status (default: true, nil for all)
  """
  @spec list_episodes_by_air_date(Scope.t(), Date.t(), Date.t(), keyword()) :: [CalendarEntry.t()]
  def list_episodes_by_air_date(%Scope{} = scope, start_date, end_date, opts \\ []) do
    monitored = Keyword.get(opts, :monitored, true)

    query =
      Episode
      |> join(:inner, [e], m in MediaItem, on: e.media_item_id == m.id)
      |> where([e, m], not is_nil(e.air_date))
      |> where([e, m], e.air_date >= ^start_date and e.air_date <= ^end_date)
      |> Restrictions.apply_to_episodes(scope)

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
  @spec list_movies_by_release_date(Scope.t(), Date.t(), Date.t(), keyword()) :: [
          CalendarEntry.t()
        ]
  def list_movies_by_release_date(%Scope{} = scope, start_date, end_date, opts \\ []) do
    monitored = Keyword.get(opts, :monitored, true)

    query =
      MediaItem
      |> Restrictions.apply(scope)
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
    - `:monitor_new?` - Required boolean. Whether newly created episodes arrive
      monitored. Compute it once per season with `should_monitor_new_episode?/2`.
  ## Returns
    - `{:ok, count}` - Number of episodes processed (created + updated)
  """
  @spec upsert_episodes_from_season(MediaItem.t(), struct(), keyword()) ::
          {:ok, non_neg_integer()}
  def upsert_episodes_from_season(media_item, season_data, opts \\ []) do
    # Required on purpose. A default here is what let the scanner and enricher
    # drift into monitoring everything regardless of the show's intent.
    monitor_new? = Keyword.fetch!(opts, :monitor_new?)

    episodes = season_data.episodes || []

    count =
      Enum.reduce(episodes, 0, fn episode, acc ->
        season_num = episode.season_number
        episode_num = episode.episode_number

        # Skip if season or episode number is nil
        if is_nil(season_num) or is_nil(episode_num) do
          acc
        else
          existing = find_existing_episode(media_item.id, episode)

          air_date = parse_air_date(episode.air_date)

          if is_nil(existing) do
            case create_episode(%{
                   media_item_id: media_item.id,
                   season_number: season_num,
                   episode_number: episode_num,
                   absolute_number: episode.absolute_number,
                   provider_episode_id: episode.provider_episode_id,
                   title: episode.name,
                   air_date: air_date,
                   metadata: Map.from_struct(episode),
                   monitored: monitor_new?
                 }) do
              {:ok, _episode} -> acc + 1
              {:error, _changeset} -> acc
            end
          else
            # Update existing episode with fresh metadata. Season/episode
            # number are included because the lookup is now keyed on
            # provider_episode_id when present — a matched episode may
            # legitimately need to move to new coordinates (a reordering).
            #
            # `absolute_number`/`provider_episode_id` are written unguarded,
            # including when the incoming value is nil. Currently unreachable
            # for a tagged row in practice — the only way to reach the update
            # branch with a nil incoming provider_episode_id is via the
            # season/episode fallback, and `fallback_by_number/2` above only
            # ever hands back an *untagged* row when the incoming id is
            # present, or the untouched row otherwise — but nothing here
            # enforces it, so a future change to that matching logic could
            # silently start clearing a tagged row's id.
            case update_episode(existing, %{
                   season_number: season_num,
                   episode_number: episode_num,
                   absolute_number: episode.absolute_number,
                   provider_episode_id: episode.provider_episode_id,
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

  # Provider episode id is the only identity stable across a season
  # reordering, so it wins when present. Without this, switching a show's
  # ordering inserts a parallel set of episodes and strands the originals,
  # along with their file links, watch history and monitored flags.
  #
  # Falls back to (season_number, episode_number) whenever the provider-id
  # lookup comes up empty — either because the incoming episode carries no
  # provider id (every TMDB-sourced show), or because it does but no row has
  # been tagged with it yet (every existing row until a backfill runs).
  # Skipping that second case would insert a duplicate row for the
  # not-yet-tagged episode at the very next refresh, colliding with the
  # (media_item_id, season_number, episode_number) unique index and failing
  # silently instead of updating the row in place.
  defp find_existing_episode(media_item_id, episode) do
    find_episode_by_provider_id(media_item_id, episode.provider_episode_id) ||
      fallback_by_number(media_item_id, episode)
  end

  defp find_episode_by_provider_id(_media_item_id, nil), do: nil

  defp find_episode_by_provider_id(media_item_id, provider_id) when is_binary(provider_id) do
    Repo.get_by(Episode, media_item_id: media_item_id, provider_episode_id: provider_id)
  end

  # No row currently carries the incoming provider id (or it has none). The
  # positional fallback is only safe to adopt when the row it finds is
  # untagged: an untagged row at these coordinates is very likely this same
  # episode, just not yet backfilled with an id. A row already tagged with a
  # *different* id is a different episode that happens to sit at the same
  # coordinates right now — adopting it would silently transfer that row's
  # identity (and its file links, watch history, monitored flag) onto the
  # incoming episode, which a later provider payload could permanently strand
  # at the wrong coordinates. Let that case fall through to create, where it
  # collides with the season/episode unique index and surfaces via the
  # {:incomplete_episode_upsert, ...} count check instead of doing this
  # silently.
  defp fallback_by_number(media_item_id, %{provider_episode_id: nil} = episode) do
    get_episode_by_number(
      Scope.system(),
      media_item_id,
      episode.season_number,
      episode.episode_number
    )
  end

  defp fallback_by_number(media_item_id, episode) do
    case get_episode_by_number(
           Scope.system(),
           media_item_id,
           episode.season_number,
           episode.episode_number
         ) do
      %Episode{provider_episode_id: nil} = untagged -> untagged
      _ -> nil
    end
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
        # Checked here, between the fetch and the write, rather than trusting
        # the struct the caller loaded. See `refresh_target_unchanged?/1`.
        if refresh_target_unchanged?(media_item) do
          upsert_season(media_item, season, season_data)
        else
          {:error, :refresh_target_changed}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp upsert_season(media_item, season, season_data) do
    # upsert_episodes_from_season/3 swallows per-episode changeset errors and
    # still reports {:ok, count}, so a season can persist fewer episodes than
    # the provider returned and look clean. That must not stamp
    # seasons_refreshed_at, or the dropped episodes stay stale until the
    # throttle expires. Compare against what was actually upsertable.
    expected =
      Enum.count(
        season_data.episodes || [],
        &(not is_nil(&1.season_number) and not is_nil(&1.episode_number))
      )

    case upsert_episodes_from_season(media_item, season_data,
           monitor_new?: should_monitor_new_episode?(media_item, season.season_number)
         ) do
      {:ok, count} when count < expected ->
        {:error, {:incomplete_episode_upsert, expected, count}}

      other ->
        other
    end
  end

  # Whether the show is still the one the in-flight season data describes.
  #
  # A refresh reads the show once, fetches every season under it, then writes.
  # Two different mutations can commit in that gap, and the fetched payload is
  # wrong for the show afterwards either way:
  #
  #   * `SeasonOrder.switch/3` remaps the episodes onto another of TVDB's
  #     parallel orderings. Writing the old ordering's coordinates back mixes
  #     the two under a `season_order` column that claims one.
  #   * `ProviderSwitch.adopt_provider_switch/4` re-identifies the show
  #     entirely, deleting and recreating every episode against a different
  #     provider. Writing the old provider's episodes into that is worse:
  #     the coordinates and the provider ids both belong to a series this is
  #     no longer.
  #
  # So the comparison covers provenance, not just ordering. `season_order`
  # alone would miss the provider switch completely, because that path clears
  # `season_order` to nil -- and the overwhelmingly common case is a show that
  # was already nil, where nil == nil reads as unchanged.
  #
  # Both mutation paths hand this function a struct consistent with its row
  # (`Refresh.run/2` passes the `update_media_item/3` result;
  # `select_and_update_provider_id/3` returns the persisted item, or the
  # untouched one when the update failed), so this cannot decline a refresh
  # that merely updated the show on its way here.
  #
  # Re-reading immediately before the write narrows the window from every HTTP
  # fetch the refresh makes to the handful of statements between this check and
  # the upsert. It does not eliminate it: that would mean holding the show's
  # row for the duration of the writes, and a write transaction per season on
  # a hot path is a worse trade than a race that self-heals.
  defp refresh_target_unchanged?(%MediaItem{} = media_item) do
    %MediaItem{
      id: id,
      season_order: season_order,
      metadata_source: metadata_source,
      tvdb_id: tvdb_id,
      tmdb_id: tmdb_id
    } = media_item

    MediaItem
    |> where([m], m.id == ^id)
    |> select([m], {m.id, m.season_order, m.metadata_source, m.tvdb_id, m.tmdb_id})
    |> Repo.one()
    |> case do
      # Matched with the id included so that a deleted show reads as changed
      # rather than colliding with a live show whose every compared column is
      # legitimately NULL -- which `Repo.one/1` would otherwise answer with a
      # bare nil either way.
      {^id, ^season_order, ^metadata_source, ^tvdb_id, ^tmdb_id} -> true
      _ -> false
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

  @doc """
  Classifies a season's monitoring state from its already-loaded episodes.

  Pure, so the UI can call it on episodes it already has in memory rather than
  issuing another query.
  """
  @spec season_monitoring_state([Episode.t()]) :: :none | :partial | :all
  def season_monitoring_state([]), do: :none

  def season_monitoring_state(episodes) do
    cond do
      Enum.all?(episodes, & &1.monitored) -> :all
      Enum.any?(episodes, & &1.monitored) -> :partial
      true -> :none
    end
  end

  @doc """
  Decides whether an episode discovered by a refresh, scan, or provider switch
  should arrive monitored.

  A new episode inherits the season it lands in, so unmonitoring a season also
  stops that season's future episodes. A season that does not exist yet has
  nothing to inherit, so it falls back to the show's `monitor_new_seasons`
  setting. Specials are opt-in: a brand-new season 0 is never admitted, but an
  existing season 0 that the user has monitored is.
  """
  @spec should_monitor_new_episode?(MediaItem.t(), integer()) :: boolean()
  def should_monitor_new_episode?(%MediaItem{monitored: false}, _season_number), do: false

  def should_monitor_new_episode?(%MediaItem{} = media_item, season_number) do
    monitored_flags =
      Episode
      |> where([e], e.media_item_id == ^media_item.id)
      |> where([e], e.season_number == ^season_number)
      |> select([e], e.monitored)
      |> Repo.all()

    case monitored_flags do
      [] -> season_number > 0 and media_item.monitor_new_seasons == :all
      flags -> Enum.any?(flags)
    end
  end

  defp apply_media_item_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:type, type}, query ->
        where(query, [m], m.type == ^type)

      {:monitored, monitored}, query ->
        where(query, [m], m.monitored == ^monitored)

      {:ids, ids}, query when is_list(ids) ->
        where(query, [m], m.id in ^ids)

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

  Pass `config` to reuse a caller's relay config; it defaults to
  `Metadata.default_relay_config/0`. A caller running against a specific relay
  must not have its recovery search silently fall back to the global default.

  Returns {:ok, provider_id, updated_media_item} or {:error, reason}
  """
  @spec recover_provider_id_by_title(MediaItem.t(), atom(), map() | nil) ::
          {:ok, integer(), MediaItem.t()} | {:error, term()}
  def recover_provider_id_by_title(%MediaItem{} = media_item, media_type, config \\ nil) do
    alias Mydia.Metadata
    config = config || Metadata.default_relay_config()
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
            case update_media_item(Scope.system(), media_item, update_attrs,
                   reason: "Provider ID recovered"
                 ) do
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

    # Determine if show is completed/ended.
    #
    # Read through MetadataAccess: `metadata` is loaded as a %MediaMetadata{}
    # struct with atom keys, so the string-keyed match this used to do could
    # never succeed. `is_completed` was therefore always false and
    # completed_show_refresh_threshold_hours was never read — every ended show
    # was throttled as if it were still airing.
    is_completed =
      case MetadataAccess.get(media_item.metadata, :status) do
        status when is_binary(status) ->
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
  @spec is_favorite?(Scope.t(), binary(), binary()) :: boolean()
  def is_favorite?(%Scope{} = scope, user_id, media_item_id) do
    visible? =
      MediaItem
      |> Restrictions.apply(scope)
      |> where([m], m.id == ^media_item_id)
      |> Repo.exists?()

    if visible? do
      user = Mydia.Accounts.get_user!(user_id)
      Mydia.Collections.is_favorite?(user, media_item_id)
    else
      false
    end
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
  @spec list_user_favorites(Scope.t(), binary(), keyword()) :: [MediaItem.t()]
  def list_user_favorites(%Scope{} = scope, user_id, opts \\ []) do
    user = Mydia.Accounts.get_user!(user_id)

    case Mydia.Collections.get_or_create_favorites(user) do
      {:ok, favorites} ->
        favorites
        |> Mydia.Collections.list_collection_items(opts)
        |> Enum.filter(&Restrictions.visible?(&1, scope))

      {:error, _} ->
        []
    end
  end
end
