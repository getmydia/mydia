defmodule Mydia.Upgrades do
  @moduledoc """
  Eligibility and pacing for automatic quality upgrades.

  Scoring cannot be expressed in SQL, so selection is two-phase: a query
  narrows to plausible rows ordered by staleness, then `Comparator` filters
  by score in Elixir and the result is truncated to the caller's limit.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Mydia.Downloads.Download
  alias Mydia.Indexers.QualityProfileResolver
  alias Mydia.Library.MediaFile
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Repo
  alias Mydia.Search.SearchBackoff
  alias Mydia.Upgrades.Comparator

  # Over-fetch factor. Most candidate rows will already be above cutoff, so
  # fetching exactly `limit` rows would routinely return a near-empty batch.
  @overfetch 5

  @spec eligible_movies(pos_integer()) :: [map()]
  def eligible_movies(limit) when is_integer(limit) and limit > 0 do
    MediaItem
    |> where([m], m.type == "movie" and m.monitored == true)
    |> where([m], m.id not in subquery(occupying_media_item_ids()))
    |> where([m], m.id not in subquery(backed_off_ids("movie")))
    |> order_by([m], asc_nulls_first: m.last_upgrade_check_at)
    |> limit(^(limit * @overfetch))
    |> preload(media_files: ^analyzed_files_query())
    |> Repo.all()
    |> Enum.flat_map(&movie_candidate/1)
    |> Enum.take(limit)
  end

  @spec eligible_episodes(pos_integer()) :: [map()]
  def eligible_episodes(limit) when is_integer(limit) and limit > 0 do
    Episode
    |> join(:inner, [e], m in assoc(e, :media_item))
    |> where([e, m], e.monitored == true and m.monitored == true)
    |> where([e, _m], e.id not in subquery(backed_off_ids("episode")))
    |> order_by([e, _m], asc_nulls_first: e.last_upgrade_check_at)
    |> limit(^(limit * @overfetch))
    |> preload([_e, _m], [:media_item, media_files: ^analyzed_files_query()])
    |> Repo.all()
    |> Enum.flat_map(&episode_candidate/1)
    |> Enum.take(limit)
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

  defp occupying_media_item_ids do
    Download.occupying()
    |> where([d], not is_nil(d.media_item_id))
    |> select([d], d.media_item_id)
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
