defmodule Mydia.Media do
  @moduledoc """
  The Media context handles movies, TV shows, and episodes.
  """

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  require Logger
  alias Mydia.Repo
  alias Mydia.Accounts.Scope

  alias Mydia.Media.{
    AvailabilityStatus,
    DiskRemoval,
    MediaItem,
    Episode,
    EpisodePlaceholder,
    CategoryClassifier
  }

  alias Mydia.Media.{ItemWrites, Monitoring, Queries, TitleMatch}
  alias Mydia.Media.ContentRating
  alias Mydia.Media.Restrictions
  alias Mydia.Metadata.Access, as: MetadataAccess
  alias Mydia.Events
  alias Mydia.MediaRequests
  alias Mydia.Library.{MediaFile, MediaFileEpisode}

  @doc "See `Mydia.Media.FileAccess.authorize/2`."
  defdelegate authorize_media_file(scope, media_file), to: Mydia.Media.FileAccess, as: :authorize

  @doc "See `Mydia.Media.FileAccess.authorize_id/2`."
  defdelegate authorize_media_file_id(scope, media_file_id),
    to: Mydia.Media.FileAccess,
    as: :authorize_id

  ## Media Items

  @doc """
  Returns the list of media items.

  ## Options
    - `:type` - Filter by type ("movie" or "tv_show")
    - `:ids` - Filter to a specific list of media item ids
    - `:monitored` - Filter by monitored status (true/false)
    - `:category` - Filter by category (atom or string, e.g., :anime_movie or "anime_movie")
    - `:exclude_categories` - Drop these categories from the result (list of atoms or strings)
    - `:category_in` - Keep only these categories in the result (list of atoms or strings)
    - `:base_query` - Ecto query to start from instead of the full MediaItem table
    - `:library_path_type` - Filter by library path type (:movies, :series, etc.)
    - `:library_path_id` - Items whose current files are in this library, plus
      items with no current files whose target library is this one
    - `:search` - Search by title (case-insensitive substring match)
    - `:added_since` - Filter to items inserted after this DateTime
    - `:limit` - Maximum number of items to return
    - `:order_by` - Field to order by (:title, :year, or :inserted_at)
    - `:preload` - List of associations to preload
  """
  @spec list_media_items(Scope.t(), keyword()) :: [MediaItem.t()]
  def list_media_items(%Scope{} = scope, opts \\ []) do
    scope
    |> media_items_query(opts)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  The filtered query `list_media_items/2` runs, without preloads.

  Takes the same filter options and applies the scope's access restrictions.
  Start here to compose on the filtered set, for instance to scope an aggregate
  to it with `subquery/1`.
  """
  @spec media_items_query(Scope.t(), keyword()) :: Ecto.Queryable.t()
  def media_items_query(%Scope{} = scope, opts \\ []) do
    (opts[:base_query] || MediaItem)
    |> Restrictions.apply(scope)
    |> Queries.apply_media_item_filters(opts)
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
    # is_nil(extra_kind) so a folder holding only bonus content does not
    # make the movie look downloaded.
    direct =
      Repo.all(
        from(f in Mydia.Library.MediaFile,
          where: is_nil(f.trashed_at) and is_nil(f.extra_kind) and f.media_item_id in ^ids,
          select: f.media_item_id
        )
      )

    via_episodes =
      Repo.all(
        from(f in Mydia.Library.MediaFile,
          join: e in Mydia.Media.Episode,
          on: e.id == f.episode_id,
          where: is_nil(f.trashed_at) and is_nil(f.extra_kind) and e.media_item_id in ^ids,
          select: e.media_item_id
        )
      )

    MapSet.new(direct ++ via_episodes)
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

  defp external_id_match(query, nil), do: oldest_match(query)

  defp external_id_match(query, type) do
    query
    |> where([m], m.type == ^type)
    |> oldest_match()
  end

  # `limit(1)` rather than a bare `Repo.one/1`: imdb_id carries no unique index,
  # so a duplicate would raise Ecto.MultipleResultsError partway through a crawl
  # and abort every remaining item. The ordering makes the pick among duplicates
  # deterministic rather than left to whatever order the database happens to
  # return, which on PostgreSQL is not guaranteed to be insertion order -- and
  # the crawl repeats daily, so a nondeterministic pick could flip the stored
  # mapping between runs.
  #
  # The `id` tie-break is load-bearing, not decoration. `MediaItem` declares
  # `timestamps(type: :utc_datetime)`, which is SECOND precision, so two rows
  # written in the same second carry identical `inserted_at` and ordering by it
  # alone leaves them an exact tie -- which PostgreSQL may break either way on
  # successive queries. That is the flip this function exists to prevent, and it
  # is reachable in production: the crawl inserts in bursts.
  #
  # Note what the tie-break does and does not buy. `id` is a random v4 UUID
  # (`@primary_key {:id, :binary_id, autogenerate: true}`), not a sequence, so
  # among rows sharing a second the winner is arbitrary -- but STABLE, which is
  # the property that matters. "Oldest wins" holds only at second granularity.
  defp oldest_match(query) do
    query
    |> order_by([m], asc: m.inserted_at, asc: m.id)
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

  @doc """
  The message a restricted account sees when `writable?/2` refuses a write.

  Every caller that can receive `{:error, :restricted}` from
  `create_media_item/3`, `update_media_item/4`, `MediaRequests.create_request/3`,
  or `Mydia.Media.Add`'s write path should show this rather than inventing its
  own wording, so the copy stays consistent and, more importantly, generic:
  it names neither the category nor the rating threshold, so a restricted
  account cannot learn the shape of its own restrictions from an error string.
  """
  @spec restricted_message() :: String.t()
  def restricted_message, do: "This title is outside what your account is allowed to access."

  defp classify_for_write("tv_show", metadata),
    do: CategoryClassifier.classify_from_metadata(:tv_show, metadata)

  defp classify_for_write(_type, metadata),
    do: CategoryClassifier.classify_from_metadata(:movie, metadata)

  defp content_rating_of(%{content_rating: rating}), do: rating
  defp content_rating_of(_metadata), do: nil

  @doc """
  Creates a media item.

  For TV shows, this automatically fetches and creates all episodes from the
  metadata provider. This ensures TV shows are never created without their
  episode data.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
    - `:season_monitoring` - For TV shows, which seasons to monitor ("all", "future", "first", "latest", "none") - defaults to "all"
    - `:skip_episode_refresh` - Skip automatic episode fetching (for tests or special cases) - defaults to false
    - `:config` - Metadata relay config forwarded to `refresh_episodes_for_tv_show/2`.
      Callers that inject a Bypass (or any non-default relay) must pass it here;
      otherwise the automatic refresh silently uses `Metadata.default_relay_config/0`.
  """
  @spec create_media_item(Scope.t(), map(), keyword()) ::
          {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t() | :restricted}
  def create_media_item(%Scope{} = scope, attrs \\ %{}, opts \\ []) do
    attrs =
      attrs
      |> maybe_put_monitored_from_opts(opts)
      |> maybe_apply_default_monitor_new_seasons(opts)

    with :ok <- ItemWrites.authorize_write(scope, attrs),
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

      # Auto-approve any pending media requests matching this item
      case MediaRequests.auto_approve_matching_requests(
             media_item,
             actor_type: actor_type,
             actor_id: actor_id,
             exclude_request_id: Keyword.get(opts, :exclude_request_id)
           ) do
        {:ok, _approved_requests} ->
          # For TV shows, automatically fetch episodes unless explicitly skipped
          if media_item.type == "tv_show" and not Keyword.get(opts, :skip_episode_refresh, false) do
            fetch_episodes_for_new_show(media_item, opts)
          end

          {:ok, media_item}

        {:error, changeset} ->
          Logger.error(
            "Failed to auto-approve requests for media #{media_item.id}: #{inspect(changeset)}"
          )

          {:error, changeset}
      end
    end
  end

  defp maybe_put_monitored_from_opts(attrs, opts) do
    if not Map.has_key?(attrs, :monitored) and not Map.has_key?(attrs, "monitored") and
         Keyword.has_key?(opts, :monitored) do
      Map.put(attrs, :monitored, opts[:monitored])
    else
      attrs
    end
  end

  defp maybe_apply_default_monitor_new_seasons(attrs, opts) do
    type = Map.get(attrs, :type) || Map.get(attrs, "type")

    if type == "tv_show" and not Map.has_key?(attrs, :monitor_new_seasons) and
         not Map.has_key?(attrs, "monitor_new_seasons") do
      case Keyword.get(opts, :season_monitoring) do
        mode when mode in ["first", "none"] ->
          Map.put(attrs, :monitor_new_seasons, :none)

        mode when mode in ["all", "future", "latest"] ->
          Map.put(attrs, :monitor_new_seasons, :all)

        _ ->
          attrs
      end
    else
      attrs
    end
  end

  @doc """
  Fetches the episodes of a just-added TV show and applies the initial season
  monitoring. Failures are logged, never raised: the show is still usable and
  its episodes can be refreshed later.

  `create_media_item/3` calls this itself unless `:skip_episode_refresh` is set.
  Callers that skip it because they are inside a transaction call this once the
  transaction has committed.

  ## Options

    * `:season_monitoring` - defaults to `"all"`
    * `:config` - relay config to use
  """
  @spec fetch_episodes_for_new_show(MediaItem.t(), keyword()) :: :ok
  def fetch_episodes_for_new_show(%MediaItem{} = media_item, opts \\ []) do
    season_monitoring = Keyword.get(opts, :season_monitoring, "all")

    refresh_opts =
      [season_monitoring: season_monitoring]
      |> maybe_put_refresh_config(Keyword.get(opts, :config))

    case refresh_episodes_for_tv_show(media_item, refresh_opts) do
      {:ok, count} ->
        Logger.info("Created #{count} episodes for #{media_item.title}")
        apply_initial_season_monitoring(media_item, season_monitoring)

      {:error, reason} ->
        Logger.warning("Failed to fetch episodes for #{media_item.title}: #{inspect(reason)}")
    end

    :ok
  end

  defp apply_initial_season_monitoring(%MediaItem{monitored: false}, _season_monitoring), do: :ok

  defp apply_initial_season_monitoring(%MediaItem{} = media_item, "future") do
    apply_episode_monitoring(media_item, :future)
  end

  defp apply_initial_season_monitoring(%MediaItem{} = media_item, "none") do
    apply_episode_monitoring(media_item, :none)
  end

  defp apply_initial_season_monitoring(%MediaItem{} = media_item, "first") do
    episodes = list_episodes(Scope.system(), media_item.id)
    {to_monitor, to_unmonitor} = Enum.split_with(episodes, fn ep -> ep.season_number == 1 end)
    Monitoring.set_episodes_monitored(to_monitor, true)
    Monitoring.set_episodes_monitored(to_unmonitor, false)
  end

  defp apply_initial_season_monitoring(%MediaItem{} = media_item, "latest") do
    episodes = list_episodes(Scope.system(), media_item.id)

    regular_seasons =
      episodes
      |> Enum.map(& &1.season_number)
      |> Enum.filter(&(&1 > 0))

    latest_season_number = if regular_seasons != [], do: Enum.max(regular_seasons), else: 0

    {to_monitor, to_unmonitor} =
      Enum.split_with(episodes, fn ep ->
        ep.season_number == latest_season_number and ep.season_number > 0
      end)

    Monitoring.set_episodes_monitored(to_monitor, true)
    Monitoring.set_episodes_monitored(to_unmonitor, false)
  end

  defp apply_initial_season_monitoring(%MediaItem{}, _all), do: :ok

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
    with :ok <-
           ItemWrites.authorize_write(scope, ItemWrites.merged_write_attrs(media_item, attrs)) do
      changeset = MediaItem.changeset(media_item, attrs)
      ItemWrites.persist_and_audit_media_item(changeset, media_item, opts)
    end
  end

  ## Item writes

  defdelegate audited_media_item_fields(), to: Mydia.Media.ItemWrites

  @doc """
  True when something other than `user_id`'s own bookkeeping depends on the item:
  a media file (movie files carry `media_item_id`, episode files only
  `episode_id`), a download, or another user's progress, collection item or
  request. Used to decide whether an item added moments ago can be withdrawn
  without taking someone else's data or files with it.
  """
  @spec in_use?(MediaItem.t(), binary()) :: boolean()
  def in_use?(%MediaItem{id: id}, user_id) do
    episode_ids = from(e in Episode, where: e.media_item_id == ^id, select: e.id)

    queries = [
      from(f in MediaFile,
        where: f.media_item_id == ^id or f.episode_id in subquery(episode_ids)
      ),
      from(l in MediaFileEpisode, where: l.episode_id in subquery(episode_ids)),
      from(d in Mydia.Downloads.Download,
        where: d.media_item_id == ^id or d.episode_id in subquery(episode_ids)
      ),
      from(p in Mydia.Playback.Progress,
        where:
          p.user_id != ^user_id and
            (p.media_item_id == ^id or p.episode_id in subquery(episode_ids))
      ),
      from(ci in Mydia.Collections.CollectionItem,
        join: c in Mydia.Collections.Collection,
        on: c.id == ci.collection_id,
        where: ci.media_item_id == ^id and c.user_id != ^user_id
      ),
      from(r in Mydia.Media.MediaRequest,
        where: r.media_item_id == ^id and r.requester_id != ^user_id
      )
    ]

    Enum.any?(queries, &Repo.exists?/1)
  end

  @doc """
  Deletes a media item.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
    - `:delete_files` - Whether to delete physical files from disk (default: false)

  When `:delete_files` is true, the database records go first, then the
  item's files, the subtitles beside them and every folder of the item that
  holds nothing else are removed from disk. See `Mydia.Media.DiskRemoval`.
  When false (default), only the database records go and every file stays.

  For a TV show, a `:delete_files` of false also demotes every episode's
  files into `import_candidates` first, so they surface again as answerable
  import work if the show is re-added. When `:delete_files` is true, no
  candidates are created for them -- the files are about to be gone, so
  there is nothing left to import.

  The third element describes what happened on disk; it is an empty
  `%DiskRemoval{}` when `:delete_files` is false.
  """
  @spec delete_media_item(Scope.t(), MediaItem.t(), keyword()) ::
          {:ok, MediaItem.t(), DiskRemoval.t()} | {:error, Ecto.Changeset.t()}
  def delete_media_item(%Scope{} = _scope, %MediaItem{} = media_item, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    Logger.info("delete_media_item called",
      media_item_id: media_item.id,
      title: media_item.title,
      delete_files: delete_files
    )

    # Plan the disk removal *before* deleting the record, while the rows that
    # name the files, their subtitles and their episodes still exist. The disk
    # is touched only after the delete commits: a failed DB delete then
    # leaves it untouched (nothing lost).
    plan = if delete_files, do: DiskRemoval.plan([media_item.id])

    # Track event before deletion (we need the media_item data)
    actor_type = Keyword.get(opts, :actor_type, :system)
    actor_id = Keyword.get(opts, :actor_id, "media_context")

    Events.media_item_removed(media_item, actor_type, actor_id)

    result =
      Repo.transaction(fn ->
        # When `delete_files` is false, the kept files are parked as
        # dismissed candidates (see `park_media_item_files/1`). When true,
        # episode rows are removed without that side effect because the
        # bytes are about to go: a candidate would be a phantom pointing at
        # a path that no longer exists. The episode media_file rows still
        # have to go before `Repo.delete(media_item)` cascades to the
        # episodes themselves, since `media_files.episode_id` is
        # `ON DELETE NO ACTION`.
        if delete_files do
          delete_media_item_episode_files(media_item)
        else
          park_media_item_files(media_item)
        end

        case Repo.delete(media_item) do
          {:ok, deleted} -> deleted
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

    case result do
      {:ok, deleted} -> {:ok, deleted, remove_from_disk(plan)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp remove_from_disk(nil), do: %DiskRemoval{}
  defp remove_from_disk(%DiskRemoval.Plan{} = plan), do: DiskRemoval.run(plan)

  @doc """
  What `delete_media_item(media_item, delete_files: true)` would remove from
  disk, for the delete dialog. Read-only and advisory: the delete checks every
  folder again. See `Mydia.Media.DiskRemoval.preview/1`.
  """
  @spec preview_disk_removal(MediaItem.t()) :: DiskRemoval.Preview.t()
  def preview_disk_removal(%MediaItem{} = media_item), do: DiskRemoval.preview(media_item)

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
  where count is the number of updated items, or `{:error, :not_found}` if
  `attrs` references a quality profile or library path that does not exist.

  When `attrs` sets `:monitored`, this records a monitoring decision for every
  affected item, exactly like `update_media_items_monitored/3` does. Without
  that, an operator re-enabling monitoring here instead of through the
  dedicated toggle would leave no decision on record, and
  `Mydia.Jobs.MonitoringRepair` would read the item's last recorded decision
  as the earlier disable and undo the re-enable on the next boot
  (getmydia/mydia#653). A batch that does not touch `:monitored` emits nothing.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
  """
  @spec update_media_items_batch(Scope.t(), [binary()], map(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, :not_found | term()}
  def update_media_items_batch(%Scope{} = _scope, ids, attrs, opts \\ [])
      when is_list(ids) and is_map(attrs) do
    if referenced_foreign_keys_exist?(attrs) do
      do_update_media_items_batch(ids, attrs, opts)
    else
      {:error, :not_found}
    end
  end

  # Repo.update_all/3 takes no changeset, so Mydia.Repo.ForeignKeyGuard cannot
  # turn a foreign key violation below into a changeset error: it raises on
  # both SQLite and PostgreSQL, unlike the changeset-backed writes elsewhere
  # in this branch. Check the referenced rows up front instead.
  defp referenced_foreign_keys_exist?(attrs) do
    reference_exists?(Mydia.Settings.QualityProfile, attrs[:quality_profile_id]) and
      reference_exists?(Mydia.Settings.LibraryPath, attrs[:library_path_id])
  end

  defp reference_exists?(_schema, nil), do: true

  defp reference_exists?(schema, id) do
    Repo.exists?(from(r in schema, where: r.id == ^id))
  rescue
    # PostgreSQL raises while binding a non-UUID-shaped id. It certainly does
    # not exist.
    Ecto.Query.CastError -> false
  end

  defp do_update_media_items_batch(ids, attrs, opts) do
    Repo.transaction(fn ->
      # Build the update list, only including non-nil values
      updates =
        attrs
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Enum.into(%{})
        |> Map.put(:updated_at, DateTime.utc_now())

      if map_size(updates) > 1 do
        # More than just updated_at

        # Fetch media items before the update, but only when the batch
        # touches :monitored: a quality-profile-only batch has nothing to
        # record and should pay no extra query.
        media_items =
          if Map.has_key?(updates, :monitored) do
            MediaItem
            |> where([m], m.id in ^ids)
            |> Repo.all()
          else
            []
          end

        {count, _} =
          MediaItem
          |> where([m], m.id in ^ids)
          |> Repo.update_all(set: Map.to_list(updates))

        unless media_items == [] do
          monitored = normalize_monitored(Map.fetch!(updates, :monitored))
          actor_type = Keyword.get(opts, :actor_type, :system)
          actor_id = Keyword.get(opts, :actor_id, "media_context")

          Enum.each(media_items, fn media_item ->
            Events.media_item_monitoring_changed(media_item, monitored, actor_type, actor_id)
          end)
        end

        count
      else
        0
      end
    end)
  end

  # The batch edit form in the LiveView posts "true"/"false" strings; direct
  # callers (tests, other contexts) pass real booleans. Repo.update_all casts
  # either shape fine for the write itself, but the monitoring_changed event's
  # metadata must carry an actual boolean, not the literal string "true".
  defp normalize_monitored(true), do: true
  defp normalize_monitored(false), do: false
  defp normalize_monitored("true"), do: true
  defp normalize_monitored("false"), do: false

  @doc """
  Deletes multiple media items in a transaction.

  ## Options
    - `:delete_files` - Whether to delete physical files from disk (default: false)

  Returns `{:ok, count, %DiskRemoval{}}`, where count is the number of deleted
  items, or `{:error, reason}` if the transaction fails.

  When `:delete_files` is true, the database records are deleted first and
  the items' files and folders are removed from disk after the commit (so a
  failed delete leaves the disk untouched). See `Mydia.Media.DiskRemoval`.
  When false (default), only removes database records and preserves files on
  disk.
  """
  @spec delete_media_items(Scope.t(), [binary()], keyword()) ::
          {:ok, non_neg_integer(), DiskRemoval.t()} | {:error, term()}
  def delete_media_items(%Scope{} = _scope, ids, opts \\ []) when is_list(ids) do
    delete_files = Keyword.get(opts, :delete_files, false)

    # One plan for every item, run once after the commit. Finishing folders
    # item by item would let a second item's not-yet-deleted files keep a
    # folder the two share. See `delete_media_item/2` for why the plan comes
    # before the delete.
    plan = if delete_files, do: DiskRemoval.plan(ids)

    result =
      Repo.transaction(fn ->
        # See the comment in `delete_media_item/2`: parking files as
        # `import_candidates` when they are about to be deleted from disk
        # anyway would leave phantom candidates pointing at paths that no
        # longer exist.
        items =
          MediaItem
          |> where([m], m.id in ^ids)
          |> Repo.all()

        if delete_files do
          items
          |> Enum.filter(&(&1.type == "tv_show"))
          |> Enum.each(&delete_media_item_episode_files/1)
        else
          Enum.each(items, &park_media_item_files/1)
        end

        # Delete the media items (and cascade delete all related DB records).
        MediaItem
        |> where([m], m.id in ^ids)
        |> Repo.delete_all()
        |> elem(0)
      end)

    case result do
      {:ok, count} -> {:ok, count, remove_from_disk(plan)}
      {:error, reason} -> {:error, reason}
    end
  end

  ## Stats

  defdelegate count_media_items(scope, opts \\ []), to: Mydia.Media.Stats
  defdelegate count_movies(scope, opts \\ []), to: Mydia.Media.Stats
  defdelegate count_tv_shows(scope, opts \\ []), to: Mydia.Media.Stats
  defdelegate count_unrated_items(scope), to: Mydia.Media.Stats
  defdelegate episode_state_counts(), to: Mydia.Media.Stats
  defdelegate get_library_status_map(scope), to: Mydia.Media.Stats
  defdelegate library_status_for_tmdb_ids(scope, tmdb_ids, type), to: Mydia.Media.Stats

  ## Episodes

  defdelegate list_episodes(scope, media_item_id, opts \\ []), to: Mydia.Media.Episodes
  defdelegate season_pack_episode_count(media_item_id, season_number), to: Mydia.Media.Episodes
  defdelegate get_episode!(scope, id, opts \\ []), to: Mydia.Media.Episodes

  defdelegate get_episode_by_number(
                scope,
                media_item_id,
                season_number,
                episode_number,
                opts \\ []
              ),
              to: Mydia.Media.Episodes

  defdelegate episode_bounds(media_item_id), to: Mydia.Media.Episodes
  defdelegate episode_coordinates(media_item_id), to: Mydia.Media.Episodes
  defdelegate get_next_episode(scope, episode, opts \\ []), to: Mydia.Media.Episodes
  defdelegate create_episode(attrs \\ %{}), to: Mydia.Media.Episodes
  defdelegate update_episode(episode, attrs), to: Mydia.Media.Episodes
  defdelegate delete_episode(episode), to: Mydia.Media.Episodes
  defdelegate change_episode(episode, attrs \\ %{}), to: Mydia.Media.Episodes

  ## Monitoring

  defdelegate update_season_monitoring(media_item_id, season_number, monitored),
    to: Mydia.Media.Monitoring

  defdelegate monitoring_presets(), to: Mydia.Media.Monitoring
  defdelegate derive_monitoring_preset(episodes), to: Mydia.Media.Monitoring
  defdelegate apply_episode_monitoring(media_item, preset), to: Mydia.Media.Monitoring
  defdelegate set_monitor_new_seasons(media_item, mode), to: Mydia.Media.Monitoring
  defdelegate season_monitoring_state(episodes), to: Mydia.Media.Monitoring

  defdelegate should_monitor_new_episode?(media_item, season_number),
    to: Mydia.Media.Monitoring

  # Removing an item while keeping its files parks those files as dismissed
  # import candidates: recorded, findable from "Find file" and the dismissed
  # filter on /review, and skipped by every scan, so nothing re-imports what
  # the user removed.
  defp park_media_item_files(%MediaItem{type: "tv_show"} = media_item) do
    Episode
    |> where([episode], episode.media_item_id == ^media_item.id)
    |> Repo.all()
    |> Enum.each(fn episode ->
      case Mydia.ImportCandidates.demote_episode_files(episode, dismiss: true) do
        {:ok, :ok} -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp park_media_item_files(%MediaItem{} = media_item) do
    case Mydia.ImportCandidates.demote_movie_files(media_item, dismiss: true) do
      {:ok, :ok} -> :ok
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  # The `delete_files: true` counterpart to `park_media_item_files/1`:
  # removes the media_file rows for every episode of this show, without
  # creating an `import_candidates` row for any of them. Still has to run
  # before `Repo.delete(media_item)` (or a bulk `Repo.delete_all/1` over
  # `MediaItem`) cascades the delete down to the episodes themselves, since
  # `media_files.episode_id` is `ON DELETE NO ACTION` -- an episode with a
  # media_file still pointing at it cannot be deleted.
  defp delete_media_item_episode_files(%MediaItem{type: "tv_show", id: media_item_id}) do
    episode_ids = from(e in Episode, where: e.media_item_id == ^media_item_id, select: e.id)

    Mydia.Library.MediaFile
    |> where([mf], mf.episode_id in subquery(episode_ids))
    |> Repo.delete_all()

    :ok
  end

  defp delete_media_item_episode_files(%MediaItem{}), do: :ok

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
    AvailabilityStatus.for_movie(
      length(media_item.media_files),
      Enum.any?(media_item.downloads, &download_active?/1),
      media_item.monitored
    )
  end

  def get_media_status(%MediaItem{type: "tv_show", episodes: episodes} = media_item) do
    AvailabilityStatus.for_series(
      episode_counts(episodes),
      episodes |> Enum.filter(& &1.monitored) |> episode_counts(),
      media_item.monitored
    )
  end

  # The counts AvailabilityStatus.for_series/3 classifies, taken from preloaded
  # episodes. Mydia.Media.LibraryListing computes the same counts in SQL.
  defp episode_counts(episodes) do
    today = Date.utc_today()

    %{
      total: length(episodes),
      downloaded: Enum.count(episodes, &(&1.media_files != [])),
      downloading:
        Enum.count(episodes, fn episode -> Enum.any?(episode.downloads, &download_active?/1) end),
      upcoming: Enum.count(episodes, &(&1.air_date && Date.compare(&1.air_date, today) == :gt))
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
      - `:config` - Metadata relay config. Defaults to `Metadata.default_relay_config/0`.
        Callers that inject a Bypass (or any non-default relay) must pass it;
        otherwise the refresh silently uses the global default.
      - `:force` - Fetch even when `seasons_refreshed_at` is inside the throttle
        window. Defaults to `false`. Pass it whenever a person asked for this
        show specifically; leave it off for sweeps. See
        `should_skip_season_refresh?/1`.
      - `:actor_type` / `:actor_id` - Recorded on the
        `media_item.episode_titles_updated` event when a title changed.
        Default `:system` / `"media_context"`.

  ## Returns
    - `{:ok, count}` - Number of episodes created
    - `{:error, reason}` - Error reason

  ## Examples

      iex> refresh_episodes_for_tv_show(media_item)
      {:ok, 236}
  """
  @spec refresh_episodes_for_tv_show(MediaItem.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def refresh_episodes_for_tv_show(media_item, opts \\ [])

  def refresh_episodes_for_tv_show(%MediaItem{type: "tv_show"} = media_item, opts) do
    alias Mydia.Metadata

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
        case TitleMatch.do_recover_provider_id_by_title(media_item, :tv_show, config) do
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
        ref = {provider_source, String.to_integer(provider_id)}

        case Metadata.fetch_by_ref(config, ref,
               media_type: :tv_show,
               season_order: media_item.season_order
             ) do
          {:ok, metadata} ->
            # Get seasons from metadata struct
            seasons = metadata.seasons || []

            Logger.info(
              "Fetching episodes for TV show: #{media_item.title}, found #{length(seasons)} seasons in metadata"
            )

            # Invalidate season cache to ensure fresh data with translations
            Enum.each(seasons, &invalidate_season_cache(media_item, provider_id, &1))

            # Fetch and create episodes for each season. Track failures: the
            # timestamp below throttles the next refresh, so stamping it after a
            # partial pass would hide the seasons that failed until the
            # threshold expires.
            {episode_count, failed_seasons, title_changes} =
              Enum.reduce_while(seasons, {0, 0, []}, fn season, {count, failed, changes} ->
                Logger.info("Processing episodes for season #{season.season_number}")

                case create_episodes_for_season(media_item, season, config) do
                  {:ok, created, season_changes} ->
                    Logger.info(
                      "Processed #{created} episodes for season #{season.season_number}"
                    )

                    {:cont, {count + created, failed, changes ++ season_changes}}

                  # An ordering switch or a provider switch landed while this
                  # pass was fetching. Every season still to come was fetched
                  # against the same now-stale show, so stop rather than log
                  # one error per remaining season. Counting it as a failure
                  # is what leaves `seasons_refreshed_at` unstamped, which is
                  # what makes the next refresh re-fetch against the show as
                  # it actually is now.
                  {:error, :refresh_target_changed, _season_changes} ->
                    Logger.warning(
                      "Aborting season refresh: show changed mid-refresh",
                      media_item_id: media_item.id
                    )

                    {:halt, {count, failed + 1, changes}}

                  {:error, reason, season_changes} ->
                    Logger.error(
                      "Failed to create episodes for season #{season.season_number}: #{inspect(reason)}"
                    )

                    {:cont, {count, failed + 1, changes ++ season_changes}}
                end
              end)

            Logger.info("Total episodes processed: #{episode_count}")

            record_title_changes(media_item, title_changes, opts)

            if failed_seasons > 0 do
              Logger.warning(
                "Not stamping seasons_refreshed_at: #{failed_seasons} season(s) failed",
                media_item_id: media_item.id
              )
            else
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
  Re-reads only the named seasons of a TV show from its provider.

  Narrower than `refresh_episodes_for_tv_show/2` on purpose, because
  `Mydia.Jobs.AiringEpisodeRefresh` calls it several times a day:

    * It never fetches the show. Each season's `tvdb_season_id` comes from the
      seasons stored in `media_item.metadata`, and a season missing there is
      skipped.
    * It never attempts title recovery. A show without a provider id returns
      `{:error, :missing_provider_id}` and is left to the weekly pass.
    * It does not update the media item row, stamp `seasons_refreshed_at`, or
      consult the season throttle.

  When an episode title changed it records one
  `media_item.episode_titles_updated` event and rewrites exported NFOs.

  ## Options
    - `:config` - Metadata relay config. Defaults to `Metadata.default_relay_config/0`.
    - `:actor_type` / `:actor_id` - Recorded on the title-change event.
      Default `:system` / `"media_context"`.

  ## Returns
    - `{:ok, title_changes}` - every named season refreshed or was skipped
    - `{:error, {:failed_seasons, count}}` - at least one season failed; title
      changes from the seasons that succeeded are still recorded
    - `{:error, :missing_provider_id}`
  """
  @spec refresh_seasons(MediaItem.t(), [non_neg_integer()], keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def refresh_seasons(media_item, season_numbers, opts \\ [])

  def refresh_seasons(%MediaItem{type: "tv_show"} = media_item, season_numbers, opts) do
    config = Keyword.get(opts, :config) || Mydia.Metadata.default_relay_config()

    case Mydia.Media.Refresh.resolve_provider(media_item) do
      {nil, _source} ->
        {:error, :missing_provider_id}

      {provider_id, _source} ->
        stored_seasons = stored_seasons_by_number(media_item)

        {title_changes, failed} =
          Enum.reduce(season_numbers, {[], 0}, fn season_number, {changes, failed} ->
            case Map.fetch(stored_seasons, season_number) do
              {:ok, season} ->
                invalidate_season_cache(media_item, to_string(provider_id), season)

                case create_episodes_for_season(media_item, season, config) do
                  {:ok, _count, season_changes} ->
                    {changes ++ season_changes, failed}

                  {:error, reason, season_changes} ->
                    Logger.warning("Season refresh failed",
                      media_item_id: media_item.id,
                      season_number: season_number,
                      reason: inspect(reason)
                    )

                    {changes ++ season_changes, failed + 1}
                end

              :error ->
                Logger.warning("Season missing from stored metadata, skipping refresh",
                  media_item_id: media_item.id,
                  season_number: season_number
                )

                {changes, failed}
            end
          end)

        record_title_changes(media_item, title_changes, opts)

        if title_changes != [] do
          Mydia.Metadata.NfoWriter.maybe_write_nfos(media_item)
        end

        if failed > 0, do: {:error, {:failed_seasons, failed}}, else: {:ok, title_changes}
    end
  end

  def refresh_seasons(%MediaItem{type: type}, _season_numbers, _opts) do
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

  # Deletes a season's Mydia-side cache entry so the next fetch goes to the
  # relay. Uses the configured language so the deleted key matches the one
  # fetch_season_by_ref_cached/4 writes under.
  defp invalidate_season_cache(media_item, provider_id, season) do
    tvdb_season_id =
      if is_nil(media_item.tvdb_id), do: nil, else: Map.get(season, :tvdb_season_id)

    provider_id
    |> Mydia.Metadata.build_season_cache_key(
      season.season_number,
      Mydia.Metadata.metadata_language(),
      tvdb_season_id
    )
    |> Mydia.Metadata.Cache.delete()
  end

  # One event per refresh, never one per season, and none when nothing
  # changed: re-reading identical titles must stay out of the activity feed.
  defp record_title_changes(_media_item, [], _opts), do: :ok

  defp record_title_changes(media_item, title_changes, opts) do
    Events.episode_titles_updated(
      media_item,
      title_changes,
      Keyword.get(opts, :actor_type, :system),
      Keyword.get(opts, :actor_id, "media_context")
    )
  end

  defp stored_seasons_by_number(%MediaItem{
         metadata: %Mydia.Metadata.Structs.MediaMetadata{seasons: seasons}
       })
       when is_list(seasons) do
    Map.new(seasons, &{&1.season_number, &1})
  end

  defp stored_seasons_by_number(%MediaItem{}), do: %{}

  ## Calendar

  defdelegate list_episodes_by_air_date(scope, start_date, end_date, opts \\ []),
    to: Mydia.Media.Calendar

  defdelegate list_movies_by_release_date(scope, start_date, end_date, opts \\ []),
    to: Mydia.Media.Calendar

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

    {count, _title_changes} = upsert_season_episodes(media_item, season_data, monitor_new?)
    {:ok, count}
  end

  # The body of upsert_episodes_from_season/3, also returning the title changes
  # it wrote so a refresh can report them. The public function keeps its
  # {:ok, count} contract for the scanner, enricher and provider switch, none of
  # which report titles.
  defp upsert_season_episodes(media_item, season_data, monitor_new?) do
    episodes = season_data.episodes || []

    {count, title_changes} =
      Enum.reduce(episodes, {0, []}, fn episode, {count, title_changes} = acc ->
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
              {:ok, _episode} -> {count + 1, title_changes}
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
              {:ok, _episode} ->
                {count + 1, maybe_add_title_change(title_changes, existing, episode)}

              {:error, _changeset} ->
                acc
            end
          end
        end
      end)

    {count, Enum.reverse(title_changes)}
  end

  defp maybe_add_title_change(title_changes, %Episode{title: old_title}, episode) do
    if EpisodePlaceholder.title_change?(old_title, episode.name) do
      change = %{
        season: episode.season_number,
        episode: episode.episode_number,
        old: old_title,
        new: episode.name
      }

      [change | title_changes]
    else
      title_changes
    end
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

    # `metadata_source` (when set) is the authoritative provenance; only fall
    # back to the legacy TVDB-precedence rule and the stored-metadata
    # provider_id when it is absent. Mirrors the full-metadata refresh in
    # refresh_metadata/1 above, which resolves the same way for the same
    # reason: a TMDB-sourced show carrying a back-filled tvdb_id must not have
    # its episodes fetched from TVDB just because that id happens to exist.
    {provider_id, provider} =
      case Mydia.Media.Refresh.resolve_provider(media_item) do
        {nil, nil} -> {nil, nil}
        {id, source} -> {to_string(id), source}
      end

    has_tvdb = provider == :tvdb

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

    ref = {provider, String.to_integer(provider_id)}

    case Metadata.fetch_season_by_ref_cached(
           config,
           ref,
           season.season_number,
           fetch_opts
         ) do
      {:ok, season_data} ->
        # Checked here, between the fetch and the write, rather than trusting
        # the struct the caller loaded. See `refresh_target_unchanged?/1`.
        if refresh_target_unchanged?(media_item) do
          upsert_season(media_item, season, season_data)
        else
          {:error, :refresh_target_changed, []}
        end

      {:error, reason} ->
        {:error, reason, []}
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

    monitor_new? = should_monitor_new_episode?(media_item, season.season_number)

    case upsert_season_episodes(media_item, season_data, monitor_new?) do
      {count, title_changes} when count < expected ->
        # The episodes upserted before the count fell short are already
        # written, so any title change among them already landed in the
        # database. Report it rather than dropping it: the caller still
        # treats this as a failed season (so seasons_refreshed_at stays
        # unstamped), but the title changes it already collected are not lost.
        {:error, {:incomplete_episode_upsert, expected, count}, title_changes}

      {count, title_changes} ->
        {:ok, count, title_changes}
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
  #   * `ProviderSwitch.adopt_provider_switch/5` re-identifies the show
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

  # A download is active until it completes or fails.
  # Mydia.Media.LibraryListing.active_downloads/0 is this predicate in SQL.
  # Change the two together.
  defp download_active?(download) do
    is_nil(download.completed_at) && is_nil(download.error_message)
  end

  ## Category Classification

  @doc """
  Updates the category of a media item.

  ## Options
    - `:override` - If true, sets `category_override` flag to prevent auto-reclassification (default: false)
    - `:reason` - Description recorded in history (e.g., "Category updated")
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)

  Refused with `{:error, :restricted}` when the item is outside what the scope
  may write, the same rule `update_media_item/4` applies.

  ## Examples

      iex> update_category(scope, media_item, :anime_movie)
      {:ok, %MediaItem{}}

      iex> update_category(scope, media_item, :anime_movie, override: true)
      {:ok, %MediaItem{category: "anime_movie", category_override: true}}
  """
  @spec update_category(Scope.t(), MediaItem.t(), atom() | String.t(), keyword()) ::
          {:ok, MediaItem.t()} | {:error, Ecto.Changeset.t() | :restricted}
  def update_category(%Scope{} = scope, %MediaItem{} = media_item, category, opts \\ []) do
    with :ok <- ItemWrites.authorize_write(scope, ItemWrites.merged_write_attrs(media_item, %{})) do
      override = Keyword.get(opts, :override, false)
      audit_opts = Keyword.take(opts, [:reason, :actor_type, :actor_id])

      changeset = MediaItem.category_changeset(media_item, category, override: override)
      ItemWrites.persist_and_audit_media_item(changeset, media_item, audit_opts)
    end
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

      case update_category(Scope.system(), media_item, category) do
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
            case update_category(Scope.system(), media_item, new_category) do
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
      on: mf.media_item_id == m.id and is_nil(mf.trashed_at) and is_nil(mf.extra_kind)
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
        on: mf.episode_id == e.id and is_nil(mf.trashed_at) and is_nil(mf.extra_kind)
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

    case TitleMatch.do_recover_provider_id_by_title(media_item, :tv_show, config) do
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

  ## Favorites

  defdelegate is_favorite?(scope, user_id, media_item_id), to: Mydia.Media.Favorites
  defdelegate toggle_favorite(user_id, media_item_id), to: Mydia.Media.Favorites
  defdelegate list_user_favorites(scope, user_id, opts \\ []), to: Mydia.Media.Favorites

  ## Title matching

  defdelegate recover_provider_id_by_title(media_item, media_type, config \\ nil),
    to: Mydia.Media.TitleMatch

  defdelegate calculate_title_match_score(result, media_item), to: Mydia.Media.TitleMatch
  defdelegate exact_title_match?(result_title, search_title), to: Mydia.Media.TitleMatch
  defdelegate year_matches?(result_year, media_year), to: Mydia.Media.TitleMatch
end
