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

  require Logger

  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.Download
  alias Mydia.Events
  alias Mydia.Indexers.QualityProfileResolver
  alias Mydia.Indexers.SearchResult
  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
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

  Excludes on the `"episode_upgrade"` backoff bucket, not `"episode"` - that
  bucket is written by `TVShowSearch`'s missing-file search paths, which
  only ever search episodes *without* a file. An episode's file-presence
  state changes over time (imported, then later trashed), so a stale
  `"episode"` backoff row from before this episode had a file must not
  suppress its upgrade eligibility, and vice versa. See
  `eligible_movies/1`'s identical namespacing for movies.
  """
  @spec eligible_episodes(pos_integer()) :: [map()]
  def eligible_episodes(limit) when is_integer(limit) and limit > 0 do
    Episode
    |> join(:inner, [e], m in assoc(e, :media_item))
    |> where([e, m], e.monitored == true and m.monitored == true)
    |> where([e, _m], e.id in subquery(analyzed_episode_ids()))
    |> where([e, _m], e.id not in subquery(occupying_episode_ids()))
    |> where([e, _m], e.id not in subquery(backed_off_ids("episode_upgrade")))
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

  @doc """
  Returns the id of the current best analyzed, untrashed file for a movie
  (`media_item_id`) or an episode (`episode_id`) — the same "current file"
  definition `eligible_movies/1` and `eligible_episodes/1` use everywhere
  else, scored against the parent show's resolved quality profile.

  Exactly one of the two arguments is expected to be non-nil; the id-less
  side is ignored. Returns `nil` when there is nothing scorable: no file at
  all, no file that survives the analyzed/untrashed filter, or no quality
  profile resolves for the parent media item.

  Used by `Mydia.Jobs.MediaImport` to resolve what a newly imported upgrade
  file supersedes — a season pack carries only one
  `"upgrade_target_media_file_id"` on the download, but each episode it
  delivers must supersede its own prior file, not that single shared id.
  """
  @spec current_best_file_id(binary() | nil, binary() | nil) :: binary() | nil
  def current_best_file_id(media_item_id, nil) when is_binary(media_item_id) do
    with %MediaItem{} = media_item <- Repo.get(MediaItem, media_item_id),
         profile when not is_nil(profile) <- QualityProfileResolver.resolve(media_item),
         {file, _score} <-
           media_item_id |> files_for_media_item() |> best_file(profile, :movie) do
      file.id
    else
      _ -> nil
    end
  end

  def current_best_file_id(nil, episode_id) when is_binary(episode_id) do
    with %Episode{} = episode <- Repo.get(Episode, episode_id),
         episode <- Repo.preload(episode, :media_item),
         profile when not is_nil(profile) <- QualityProfileResolver.resolve(episode.media_item),
         {file, _score} <-
           episode_id |> files_for_episode() |> best_file(profile, :episode) do
      file.id
    else
      _ -> nil
    end
  end

  def current_best_file_id(_media_item_id, _episode_id), do: nil

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

  @doc """
  Resolves the outcome of a completed automatic-upgrade import (Task 10).

  Called once the just-imported file's own analysis lands — see
  `Mydia.Library.apply_analysis/2`'s success path and
  `Mydia.Jobs.UpgradeFinalize`, which enqueues this the moment a file with a
  non-nil `supersedes_media_file_id` finishes analysis. That is the first
  moment the new file can be scored, and therefore the first moment this
  decision can be made.

  Scores the file at `media_file_id` and the file it claims to supersede
  against the *same* resolved profile — never two different profiles, which
  would make the comparison meaningless — via
  `Comparator.score_file_with_breakdown/3`, then picks exactly one of four
  outcomes:

    * `{:ok, :upgraded}` — the new file cleared `min_upgrade_margin`. The
      old file is trashed (`Library.trash_media_file/1` — never a hard
      delete, so a wrong call stays recoverable for the trash retention
      window), `Events.file_upgraded/4` records both scores and the
      per-dimension breakdown delta, and the pointer is cleared.
    * `{:ok, :rejected}` — it didn't clear the margin. The release lied
      about its contents: the *new* file is trashed instead, its
      originating release is blacklisted (`Downloads.Blacklists`) so the
      next sweep doesn't grab it again tomorrow, `Events.upgrade_rejected/4`
      records the trail, and the pointer is cleared.
    * `{:ok, :orphaned}` — the file the new one claims to supersede is gone
      (deleted, or trashed by something else between grab and finalize).
      The pointer is cleared and the new file is kept as an ordinary
      import.
    * `{:ok, :noop}` — `supersedes_media_file_id` was already nil (already
      finalized, or the file was never an upgrade import in the first
      place). Nothing to do.

  Every terminal branch clears the pointer — that, not the worker's
  `unique` constraint, is what makes re-running this on an already-processed
  file safe: a second call always lands on `{:ok, :noop}`.
  """
  @spec finalize_upgrade(binary()) ::
          {:ok, :upgraded | :rejected | :orphaned | :noop}
          | {:error, :unscorable | Ecto.Changeset.t()}
  def finalize_upgrade(media_file_id) when is_binary(media_file_id) do
    case Repo.get(MediaFile, media_file_id) do
      nil ->
        {:ok, :noop}

      %MediaFile{supersedes_media_file_id: nil} ->
        {:ok, :noop}

      %MediaFile{} = new_file ->
        case superseded_file(new_file) do
          nil ->
            with {:ok, _} <- clear_pointer(new_file) do
              {:ok, :orphaned}
            end

          %MediaFile{} = old_file ->
            finalize_comparison(new_file, old_file)
        end
    end
  end

  # The file `new_file` claims to supersede, or nil when it is not there to
  # be compared against anymore — hard-deleted, or trashed by something else
  # (a manual cleanup, a re-scan) between the grab and this finalize.
  defp superseded_file(%MediaFile{supersedes_media_file_id: id}) do
    case Repo.get(MediaFile, id) do
      nil -> nil
      %MediaFile{trashed_at: nil} = old -> old
      %MediaFile{} -> nil
    end
  end

  defp finalize_comparison(new_file, old_file) do
    {media_type, media_item} = resolve_media_context(new_file)
    profile = media_item && QualityProfileResolver.resolve(media_item)

    with %QualityProfile{} <- profile,
         {:ok, %{score: old_score, breakdown: old_breakdown}} <-
           Comparator.score_file_with_breakdown(old_file, profile, media_type),
         {:ok, %{score: new_score, breakdown: new_breakdown}} <-
           Comparator.score_file_with_breakdown(new_file, profile, media_type) do
      margin = profile.min_upgrade_margin || 0
      delta = Float.round(new_score - old_score, 1)

      comparison = %{
        old_score: old_score,
        new_score: new_score,
        delta: delta,
        old_breakdown: old_breakdown,
        new_breakdown: new_breakdown,
        breakdown_delta: breakdown_delta(old_breakdown, new_breakdown)
      }

      if delta >= margin do
        apply_upgrade(new_file, old_file, media_item, comparison)
      else
        apply_rejection(new_file, old_file, media_item, comparison)
      end
    else
      _ ->
        Logger.error(
          "Cannot finalize upgrade: no quality profile resolved, or a file is unscorable",
          media_file_id: new_file.id,
          superseded_media_file_id: old_file.id
        )

        {:error, :unscorable}
    end
  end

  defp resolve_media_context(%MediaFile{episode_id: episode_id}) when not is_nil(episode_id) do
    case Repo.get(Episode, episode_id) do
      nil -> {:episode, nil}
      episode -> {:episode, Repo.preload(episode, :media_item).media_item}
    end
  end

  defp resolve_media_context(%MediaFile{media_item_id: media_item_id})
       when not is_nil(media_item_id) do
    {:movie, Repo.get(MediaItem, media_item_id)}
  end

  defp resolve_media_context(%MediaFile{}), do: {nil, nil}

  defp apply_upgrade(new_file, old_file, media_item, comparison) do
    with {:ok, trashed_old} <- Library.trash_media_file(old_file),
         {:ok, _new_file} <- clear_pointer(new_file) do
      Events.file_upgraded(new_file, trashed_old, media_item, comparison)
      {:ok, :upgraded}
    end
  end

  defp apply_rejection(new_file, old_file, media_item, comparison) do
    with {:ok, trashed_new} <- Library.trash_media_file(new_file),
         {:ok, _new_file} <- clear_pointer(trashed_new) do
      blacklist_release(trashed_new)
      Events.upgrade_rejected(trashed_new, old_file, media_item, comparison)
      {:ok, :rejected}
    end
  end

  defp clear_pointer(%MediaFile{} = media_file) do
    media_file
    |> Ecto.Changeset.change(supersedes_media_file_id: nil)
    |> Repo.update()
  end

  # Per-profile-dimension delta (new - old), rounded the same way
  # Comparator.upgrade?/5 rounds its overall delta. Read by the activity
  # feed to answer *why* a replacement decision was made, not just report
  # the aggregate score change.
  defp breakdown_delta(old_breakdown, new_breakdown) do
    old_breakdown
    |> Map.keys()
    |> Kernel.++(Map.keys(new_breakdown))
    |> Enum.uniq()
    |> Map.new(fn dimension ->
      old_value = Map.get(old_breakdown, dimension, 0.0) || 0.0
      new_value = Map.get(new_breakdown, dimension, 0.0) || 0.0
      {dimension, Float.round(new_value - old_value, 1)}
    end)
  end

  # Blacklisting a rejected upgrade's release is not optional: without it,
  # the next sweep grabs the exact same lying release, imports it, rejects
  # it, and repeats forever. The (indexer, guid) pair is reached by tracing
  # new_file's `metadata.extra["imported_from_download_id"]` (written by
  # `Mydia.Jobs.MediaImport` on every import) back to the `Download` row,
  # which always carries `indexer` and a `metadata["guid"]` — real, or a
  # deterministic fallback synthesized by
  # `Mydia.Downloads.Queue.build_download_metadata/1` when the indexer
  # didn't supply one. A failure to resolve either is logged loudly rather
  # than silently skipped, but does not block the rejection outcome: the
  # file is already trashed and the pointer already cleared by the time
  # this runs, and blocking the whole job retrying forever on a
  # permanently-missing download record would be worse than a logged gap in
  # the blacklist.
  defp blacklist_release(new_file) do
    with download_id when is_binary(download_id) <- download_id_for(new_file),
         %Download{} = download <- Repo.get(Download, download_id),
         guid when is_binary(guid) and guid != "" <- get_in(download.metadata || %{}, ["guid"]),
         indexer when is_binary(indexer) and indexer != "" <- download.indexer do
      case Blacklists.add(indexer, guid, download.title || "Unknown release", "upgrade_rejected") do
        {:ok, _row} ->
          :ok

        {:error, changeset} ->
          Logger.error("Failed to blacklist rejected upgrade release",
            media_file_id: new_file.id,
            download_id: download_id,
            errors: inspect(changeset.errors)
          )

          :ok
      end
    else
      _ ->
        Logger.error(
          "Could not blacklist rejected upgrade release: no traceable (indexer, guid) " <>
            "for the originating download",
          media_file_id: new_file.id
        )

        :ok
    end
  end

  defp download_id_for(%MediaFile{metadata: %FileMetadata{extra: extra}}) when is_map(extra) do
    case extra["imported_from_download_id"] do
      id when is_binary(id) -> id
      _ -> nil
    end
  end

  defp download_id_for(%MediaFile{}), do: nil

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

  defp files_for_media_item(media_item_id) do
    analyzed_files_query()
    |> where([f], f.media_item_id == ^media_item_id)
    |> Repo.all()
  end

  defp files_for_episode(episode_id) do
    analyzed_files_query()
    |> where([f], f.episode_id == ^episode_id)
    |> Repo.all()
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
