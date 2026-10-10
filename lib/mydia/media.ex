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
    MediaItem,
    Episode,
    CategoryClassifier
  }

  alias Mydia.Media.{ItemWrites, Monitoring, Queries}
  alias Mydia.Media.ContentRating
  alias Mydia.Media.Restrictions
  alias Mydia.Events
  alias Mydia.MediaRequests

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

  ## Deletion

  defdelegate in_use?(media_item, user_id), to: Mydia.Media.Deletion
  defdelegate delete_media_item(scope, media_item, opts \\ []), to: Mydia.Media.Deletion
  defdelegate preview_disk_removal(media_item), to: Mydia.Media.Deletion
  defdelegate delete_media_items(scope, ids, opts \\ []), to: Mydia.Media.Deletion

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

  ## Bulk writes

  defdelegate update_media_items_monitored(scope, ids, monitored, opts \\ []),
    to: Mydia.Media.BulkWrites

  defdelegate update_media_items_batch(scope, ids, attrs, opts \\ []),
    to: Mydia.Media.BulkWrites

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

  ## Episode sync

  defdelegate refresh_episodes_for_tv_show(media_item, opts \\ []), to: Mydia.Media.EpisodeSync
  defdelegate refresh_seasons(media_item, season_numbers, opts \\ []), to: Mydia.Media.EpisodeSync
  defdelegate stamp_seasons_refreshed(media_item), to: Mydia.Media.EpisodeSync

  defdelegate upsert_episodes_from_season(media_item, season_data, opts \\ []),
    to: Mydia.Media.EpisodeSync

  ## Calendar

  defdelegate list_episodes_by_air_date(scope, start_date, end_date, opts \\ []),
    to: Mydia.Media.Calendar

  defdelegate list_movies_by_release_date(scope, start_date, end_date, opts \\ []),
    to: Mydia.Media.Calendar

  # A download is active until it completes or fails.
  # Mydia.Media.LibraryListing.active_downloads/0 is this predicate in SQL.
  # Change the two together.
  defp download_active?(download) do
    is_nil(download.completed_at) && is_nil(download.error_message)
  end

  ## Category Classification

  defdelegate update_category(scope, media_item, category, opts \\ []),
    to: Mydia.Media.Categorization

  defdelegate clear_category_override(media_item), to: Mydia.Media.Categorization
  defdelegate reclassify_media_item(media_item, opts \\ []), to: Mydia.Media.Categorization
  defdelegate reclassify_all_media_items(), to: Mydia.Media.Categorization
  defdelegate reclassify_media_items(ids, opts \\ []), to: Mydia.Media.Categorization
  defdelegate partition_for_auto_search(ids), to: Mydia.Media.Categorization

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
