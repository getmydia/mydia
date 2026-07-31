defmodule Mydia.Upgrades do
  @moduledoc """
  Eligibility and pacing for automatic quality upgrades.

  Scoring cannot be expressed in SQL, so selection is two-phase: a query
  narrows to plausible rows ordered by staleness, then `Comparator` filters
  by score in Elixir. `eligible_movies/1` truncates that filtered result to
  the caller's `limit` — one movie is exactly one search, so item count and
  search-cost budget are the same number. `eligible_episodes/1` does not:
  see its own doc for why.
  """

  import Ecto.Query, warn: false

  alias Mydia.Downloads.Download
  alias Mydia.Indexers.QualityProfileResolver
  alias Mydia.Indexers.SearchResult
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.Quality
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Repo
  alias Mydia.Search.SearchBackoff
  alias Mydia.Settings.QualityProfile
  alias Mydia.Upgrades.Comparator

  # Over-fetch factor. Most candidate rows will already be above cutoff, so
  # fetching exactly `limit` rows would routinely return a near-empty batch.
  @overfetch 5

  @doc """
  Returns up to `limit` below-cutoff movies, ordered by staleness.

  One movie costs exactly one search, so `limit` doubles as a search-cost
  ceiling here: the result is truncated to `limit` after scoring.
  """
  @spec eligible_movies(pos_integer()) :: [map()]
  def eligible_movies(limit) when is_integer(limit) and limit > 0 do
    MediaItem
    |> where([m], m.type == "movie" and m.monitored == true)
    |> where([m], m.id in subquery(analyzed_movie_ids()))
    |> where([m], m.id not in subquery(occupying_media_item_ids()))
    |> where([m], m.id not in subquery(backed_off_ids("movie_upgrade")))
    |> order_by([m], asc_nulls_first: m.last_upgrade_check_at)
    |> limit(^(limit * @overfetch))
    |> preload(media_files: ^analyzed_files_query())
    |> Repo.all()
    |> Enum.flat_map(&movie_candidate/1)
    |> Enum.take(limit)
  end

  @doc """
  Returns below-cutoff episodes, ordered by staleness.

  Unlike `eligible_movies/1`, `limit` is **not** a cap on the number of
  results — it is not the same kind of budget. A season pack can turn many
  episodes into a single search, so item count and search count diverge;
  callers that need to cap actual search cost must do so themselves after
  grouping episodes by season (see `Mydia.Jobs.UpgradeSweep`).

  Truncating the result list to `limit` would risk cutting a season's
  below-cutoff episodes off mid-group, corrupting the percentage
  `Mydia.Jobs.TVShowSearch.should_prefer_season_pack?/3` computes: a season
  that would clear the 70% pack threshold in full could fall short of it
  when only a partial, arbitrarily-truncated slice of its episodes is
  visible. So `limit` only sizes the SQL-layer over-fetch page
  (`limit * #{@overfetch}` raw episode rows scanned before below-cutoff
  filtering, generous enough that whole seasons normally stay together) —
  every below-cutoff episode found within that page is returned.
  """
  @spec eligible_episodes(pos_integer()) :: [map()]
  def eligible_episodes(limit) when is_integer(limit) and limit > 0 do
    Episode
    |> join(:inner, [e], m in assoc(e, :media_item))
    |> where([e, m], e.monitored == true and m.monitored == true)
    |> where([e, _m], e.id in subquery(analyzed_episode_ids()))
    |> where([e, _m], e.id not in subquery(occupying_episode_ids()))
    |> where([e, _m], e.id not in subquery(backed_off_ids("episode")))
    |> order_by([e, _m], asc_nulls_first: e.last_upgrade_check_at)
    |> limit(^(limit * @overfetch))
    |> preload([_e, _m], [:media_item, media_files: ^analyzed_files_query()])
    |> Repo.all()
    |> Enum.flat_map(&episode_candidate/1)
  end

  @doc """
  Filters candidate search results down to the ones that are a genuine
  upgrade over `file`, per `Comparator.upgrade?/5` - the sole authority on
  that question. Shared between `MovieSearch` and the TV upgrade search path:
  only `media_type` (`:movie` or `:episode`) differs between callers, so this
  is called once with each rather than duplicated per media type.

  A candidate whose release title never parsed into a `%Quality{}` struct
  (e.g. `result.quality` is `nil`) is dropped defensively rather than passed
  to `Comparator.upgrade?/5`, which requires one.
  """
  @spec filter_candidates(
          [SearchResult.t()],
          MediaFile.t(),
          QualityProfile.t(),
          :movie | :episode
        ) :: [SearchResult.t()]
  def filter_candidates(results, %MediaFile{} = file, %QualityProfile{} = profile, media_type)
      when is_list(results) and media_type in [:movie, :episode] do
    Enum.filter(results, fn result ->
      case result.quality do
        %Quality{} = quality ->
          match?({:ok, _}, Comparator.upgrade?(file, quality, result.size, profile, media_type))

        _ ->
          false
      end
    end)
  end

  @spec stamp_checked(:movie | :episode, [binary()]) :: {non_neg_integer(), nil}
  def stamp_checked(_type, []), do: {0, nil}

  def stamp_checked(:movie, ids) when is_list(ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    MediaItem
    |> where([m], m.id in ^ids)
    |> Repo.update_all(set: [last_upgrade_check_at: now])
  end

  def stamp_checked(:episode, ids) when is_list(ids) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Episode
    |> where([e], e.id in ^ids)
    |> Repo.update_all(set: [last_upgrade_check_at: now])
  end

  defp movie_candidate(%MediaItem{} = item) do
    with profile when not is_nil(profile) <- QualityProfileResolver.resolve(item),
         {file, score} <- best_file(item.media_files, profile, :movie),
         true <- Comparator.below_cutoff?(file, profile, :movie) do
      [%{media_item: item, media_file: file, profile: profile, score: score}]
    else
      _ -> []
    end
  end

  defp episode_candidate(%Episode{} = episode) do
    with profile when not is_nil(profile) <- QualityProfileResolver.resolve(episode.media_item),
         {file, score} <- best_file(episode.media_files, profile, :episode),
         true <- Comparator.below_cutoff?(file, profile, :episode) do
      [%{episode: episode, media_file: file, profile: profile, score: score}]
    else
      _ -> []
    end
  end

  # "The current file" for the whole feature: the highest-scoring analyzed
  # untrashed file. Unanalyzed files are filtered out by the preload query
  # before scoring, never scored and discarded. The winning score is
  # returned alongside the file since scoring it again would be redundant.
  defp best_file(files, profile, media_type) when is_list(files) do
    files
    |> Enum.flat_map(fn file ->
      case Comparator.score_file(file, profile, media_type) do
        {:ok, score} -> [{score, file}]
        {:error, :unscorable} -> []
      end
    end)
    |> Enum.max_by(fn {score, _file} -> score end, fn -> nil end)
    |> case do
      nil -> nil
      {score, file} -> {file, score}
    end
  end

  defp best_file(_files, _profile, _media_type), do: nil

  defp analyzed_files_query do
    from f in MediaFile,
      where: is_nil(f.trashed_at) and not is_nil(f.analyzed_at)
  end

  # SQL-level narrowing to items that even have a scorable file, so an
  # unanalyzed item (fresh off a large import, before background analysis
  # catches up) never consumes a slot in the `@overfetch` page.
  defp analyzed_movie_ids do
    MediaFile
    |> where(
      [f],
      is_nil(f.trashed_at) and not is_nil(f.analyzed_at) and not is_nil(f.media_item_id)
    )
    |> select([f], f.media_item_id)
    |> distinct(true)
  end

  defp analyzed_episode_ids do
    MediaFile
    |> where([f], is_nil(f.trashed_at) and not is_nil(f.analyzed_at) and not is_nil(f.episode_id))
    |> select([f], f.episode_id)
    |> distinct(true)
  end

  defp occupying_media_item_ids do
    Download.occupying()
    |> where([d], not is_nil(d.media_item_id))
    |> select([d], d.media_item_id)
    |> distinct(true)
  end

  defp occupying_episode_ids do
    Download.occupying()
    |> where([d], not is_nil(d.episode_id))
    |> select([d], d.episode_id)
    |> distinct(true)
  end

  defp backed_off_ids(resource_type) do
    now = DateTime.utc_now()

    SearchBackoff
    |> where([b], b.resource_type == ^resource_type)
    |> where([b], not is_nil(b.next_eligible_at) and b.next_eligible_at > ^now)
    |> select([b], b.resource_id)
  end
end
