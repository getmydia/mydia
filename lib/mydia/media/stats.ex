defmodule Mydia.Media.Stats do
  @moduledoc """
  Counts and library-status lookups over media items and episodes.
  """

  import Ecto.Query, warn: false
  alias Mydia.Repo
  alias Mydia.Accounts.Scope
  alias Mydia.Media.{Episode, MediaItem, ProviderKey, Queries, Restrictions}
  alias Mydia.Library.{MediaFile, MediaFileEpisode}

  @doc """
  Returns the count of media items matching the given filter options.

  Accepts the same options as `list_media_items/1`, but aggregates in the
  database instead of loading rows.
  """
  @spec count_media_items(Scope.t(), keyword()) :: non_neg_integer()
  def count_media_items(%Scope{} = scope, opts \\ []) do
    (opts[:base_query] || MediaItem)
    |> Restrictions.apply(scope)
    |> Queries.apply_media_item_filters(opts)
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the count of movies in the library.

  ## Options
    - `:exclude_categories` - Drop these categories from the count
  """
  @spec count_movies(Scope.t(), keyword()) :: non_neg_integer()
  def count_movies(%Scope{} = scope, opts \\ []) do
    count_media_items(
      scope,
      Keyword.merge(Keyword.take(opts, [:exclude_categories]), type: "movie")
    )
  end

  @doc """
  Returns the count of TV shows in the library.

  ## Options
    - `:exclude_categories` - Drop these categories from the count
  """
  @spec count_tv_shows(Scope.t(), keyword()) :: non_neg_integer()
  def count_tv_shows(%Scope{} = scope, opts \\ []) do
    count_media_items(
      scope,
      Keyword.merge(Keyword.take(opts, [:exclude_categories]), type: "tv_show")
    )
  end

  @doc """
  Counts library items with no derived content rating.

  An active age limit hides every one of these, so the admin UI states the
  number at the point an operator chooses a limit rather than leaving them to
  discover a sparse library and file a bug.
  """
  @spec count_unrated_items(Scope.t()) :: non_neg_integer()
  def count_unrated_items(%Scope{} = scope) do
    MediaItem
    |> Restrictions.apply(scope)
    |> where([m], is_nil(m.content_rating_age))
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Counts episodes by availability state and monitored flag, for metrics.

  States follow `Mydia.Media.EpisodeStatus.get_episode_status/1`: `"downloaded"`
  when a non-trashed, non-extra file is linked through `media_file_episodes`
  (the association the episode page uses), else `"tba"` without an air date,
  `"upcoming"` when it airs after today, otherwise `"missing"`. Only non-empty
  combinations are returned.
  """
  @spec episode_state_counts() :: %{{String.t(), boolean()} => non_neg_integer()}
  def episode_state_counts do
    today = Date.utc_today()

    # This goes through media_file_episodes rather than media_files.episode_id,
    # so the trailing episodes of a multi-episode file count as downloaded, and
    # through MediaFile.versions/0 so the trash/extra rule lives in the one
    # place that already owns it.
    linked =
      from(mf in MediaFile.versions(),
        join: mfe in MediaFileEpisode,
        on: mfe.media_file_id == mf.id,
        distinct: true,
        select: %{episode_id: mfe.episode_id}
      )

    Episode
    |> join(:left, [e], l in subquery(linked), on: l.episode_id == e.id)
    |> select([e, l], %{
      downloaded: not is_nil(l.episode_id),
      tba: is_nil(e.air_date),
      upcoming: e.air_date > ^today,
      monitored: e.monitored
    })
    |> subquery()
    |> group_by([s], [s.downloaded, s.tba, s.upcoming, s.monitored])
    |> select([s], {s.downloaded, s.tba, s.upcoming, s.monitored, count()})
    |> Repo.all()
    |> Enum.reduce(%{}, fn {downloaded, tba, upcoming, monitored, count}, acc ->
      state = episode_state(truthy?(downloaded), truthy?(tba), truthy?(upcoming))
      Map.update(acc, {state, truthy?(monitored)}, count, &(&1 + count))
    end)
  end

  defp episode_state(true, _tba, _upcoming), do: "downloaded"
  defp episode_state(false, true, _upcoming), do: "tba"
  defp episode_state(false, false, true), do: "upcoming"
  defp episode_state(false, false, _upcoming), do: "missing"

  # SQLite returns boolean expressions as 0/1 integers, PostgreSQL as booleans.
  # A NULL comparison (upcoming on a NULL air_date) comes back as nil.
  defp truthy?(value), do: value in [true, 1]

  @doc """
  Returns a map of `{type, provider, provider_id}` to library status for
  efficient lookup.

  The key is a 3-tuple because neither of its parts is unique on its own. TMDB
  and TVDB number their catalogues independently, so `671` names a different
  title on each, and since provider-id uniqueness was scoped by type a movie
  and a show may hold the same provider id legitimately. Keying on the bare
  integer collapsed all three of those into one entry, and whichever row the
  query happened to reach last won.

  Values are maps with:
  - `:in_library` - boolean
  - `:monitored` - boolean (if in library)
  - `:type` - "movie" or "tv_show" (if in library)
  - `:id` - database ID (if in library)

  ## Examples

      iex> get_library_status_map()
      %{
        {:movie, :tmdb, 12345} => %{in_library: true, monitored: true, type: "movie", id: 1},
        {:tv_show, :tvdb, 67890} => %{in_library: true, monitored: false, type: "tv_show", id: 2}
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

      acc = put_status(acc, ProviderKey.new(type, :tmdb, tmdb_id), entry)
      put_status(acc, ProviderKey.new(type, :tvdb, tvdb_id), entry)
    end)
  end

  defp put_status(acc, nil, _entry), do: acc
  defp put_status(acc, key, entry), do: Map.put(acc, key, entry)

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
      %{{:movie, :tmdb, 671} => %{in_library: true, monitored: true, type: "movie", id: "..."}}

  The key shape matches `get_library_status_map/0` even though this query is
  already scoped to one type and one provider, so the two are interchangeable
  wherever a status map is consumed. `MediaAddHelpers.enrich_with_library_status/2`
  takes either one and needs only a single lookup.
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
      {ProviderKey.new(type, :tmdb, tmdb_id),
       %{in_library: true, monitored: monitored, type: type, id: id}}
    end)
  end
end
