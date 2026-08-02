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
  alias Mydia.Downloads.Queue
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

  `occupying_episode_ids/0` cannot see a season-pack download - it carries
  `media_item_id` plus `metadata.season_pack` and no `episode_id` - so the
  result is additionally filtered through
  `Mydia.Downloads.Queue.reject_episodes_in_active_season_packs/1`, the same
  helper the missing-file path uses. Without it, an episode inside an
  in-flight pack upgrade keeps generating searches every day, and once the
  season drops below the 70% pack threshold it generates individual grabs
  that succeed, because `check_for_active_download/4`'s `episode_id` arm
  cannot see the pack either.
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
    |> Queue.reject_episodes_in_active_season_packs()
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
  `Comparator.score_file_with_breakdown/3`, then picks exactly one of five
  outcomes:

    * `{:ok, :upgraded}` — the new file cleared `min_upgrade_margin` (via
      `Comparator.clears_margin?/2`, which treats an exact tie as *not* an
      upgrade even at margin 0). The old file is trashed
      (`Library.trash_media_file/1` — never a hard delete, so a wrong call
      stays recoverable for the trash retention window; the file itself
      moves off the library path into the trash directory, see
      `Mydia.Library.TrashStore`), `Events.file_upgraded/4` records both
      scores and the per-dimension breakdown delta, and the pointer is
      cleared.
    * `{:ok, :rejected}` — it didn't clear the margin. The *new* file is
      trashed instead. Unless it came from a season pack, its originating
      release is also blacklisted (`Downloads.Blacklists`) so the next sweep
      doesn't grab the same lying release tomorrow; a season pack is left
      grabbable, because an above-cutoff episode inside a pack is *designed*
      to fail this gate and blacklisting would burn a release that
      legitimately upgraded the rest of the season.
      `Events.upgrade_rejected/5` records the trail (including whether the
      release was blacklisted), and the pointer is cleared.
    * `{:ok, :orphaned}` — the file the new one claims to supersede is gone:
      trashed by something else between grab and finalize (a hard delete
      instead nilifies the pointer at the DB level via `on_delete:
      :nilify_all`, which lands on `:noop` before this function's logic
      even runs — see the migration). The pointer is cleared and the new
      file is kept as an ordinary import.
    * `{:ok, :noop}` — nothing to do. `supersedes_media_file_id` was
      already nil (already finalized, or the file was never an upgrade
      import), or the new file has itself been trashed by something else in
      the window between analysis landing and this job running (an
      operator action, a re-scan, or a prior partially-failed run of this
      same job) — a trashed new file can never win the comparison, and
      scoring it as live would risk trashing the old file too, leaving zero
      active copies. The pointer is cleared either way.
    * `{:ok, :unscorable}` — the comparison itself could not be scored: no
      quality profile resolves (deleted, or the file is attached to
      neither a media item nor an episode) or one of the two files failed
      `Comparator.score_file_with_breakdown/3`. These conditions are
      permanent, not transient, so retrying would only strand the pointer
      forever with both files left active. The pointer is cleared, an
      operator-visible `Events.job_failed/3` event is recorded, and both
      files are left as ordinary imports.

  Every terminal branch clears the pointer — that, not the worker's
  `unique` constraint, is what makes re-running this on an already-processed
  file safe: a second call always lands on `{:ok, :noop}`.

  Every terminal branch that trashes a file can also fail: the file has to
  physically leave the library path, and a move that fails must not leave a
  row marked trashed. `{:error, reason}` propagates to
  `Mydia.Jobs.UpgradeFinalize`, which lets Oban retry - correct, since a
  failed move is usually transient (full disk, a permissions blip).
  """
  @spec finalize_upgrade(binary()) ::
          {:ok, :upgraded | :rejected | :orphaned | :noop | :unscorable}
          | {:error, Ecto.Changeset.t() | term()}
  def finalize_upgrade(media_file_id) when is_binary(media_file_id) do
    case Repo.get(MediaFile, media_file_id) do
      nil ->
        {:ok, :noop}

      %MediaFile{supersedes_media_file_id: nil} ->
        {:ok, :noop}

      %MediaFile{trashed_at: trashed_at} = new_file when not is_nil(trashed_at) ->
        # Task 10 review finding 1 (CRITICAL): the new file itself may have
        # been trashed by something else — an operator action, a re-scan, a
        # cleanup — in the window between analysis landing and this job
        # running, or by a prior, partially-failed run of THIS job (trash
        # succeeded, clear_pointer did not, Oban retries). Scoring a trashed
        # file as a live candidate would let the upgrade branch trash the
        # *old* file too, leaving zero active copies for this episode/movie
        # until TrashCleanup permanently deletes both after the retention
        # window. A trashed new file can never win this comparison — clear
        # the pointer and stop before scoring anything.
        with {:ok, _} <- clear_pointer(new_file) do
          {:ok, :noop}
        end

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

    case profile do
      nil ->
        # media_item itself may be nil here too — a dangling FK on
        # media_item_id/episode_id (the referenced row was hard-deleted), or
        # a media file attached to neither (a specialized-library file that
        # should never have carried a supersedes pointer in the first
        # place). Either way there is nothing to resolve a profile from.
        handle_unscorable(new_file, old_file, media_item, :no_quality_profile)

      %QualityProfile{} = profile ->
        finalize_scored_comparison(new_file, old_file, media_item, media_type, profile)
    end
  end

  defp finalize_scored_comparison(new_file, old_file, media_item, media_type, profile) do
    old_result = Comparator.score_file_with_breakdown(old_file, profile, media_type)
    new_result = Comparator.score_file_with_breakdown(new_file, profile, media_type)

    case {old_result, new_result} do
      {{:ok, %{score: old_score, breakdown: old_breakdown}},
       {:ok, %{score: new_score, breakdown: new_breakdown}}} ->
        delta = Float.round(new_score - old_score, 1)

        comparison = %{
          old_score: old_score,
          new_score: new_score,
          delta: delta,
          old_breakdown: old_breakdown,
          new_breakdown: new_breakdown,
          breakdown_delta: breakdown_delta(old_breakdown, new_breakdown)
        }

        # Comparator.clears_margin?/2 is the single authority on the margin,
        # shared with upgrade?/5 so the gate that picks a candidate and the
        # gate that accepts the imported file cannot disagree - in particular
        # about whether an exact tie counts (it does not).
        if Comparator.clears_margin?(delta, profile) do
          apply_upgrade(new_file, old_file, media_item, comparison)
        else
          apply_rejection(new_file, old_file, media_item, comparison)
        end

      {{:error, :unscorable}, _} ->
        handle_unscorable(new_file, old_file, media_item, :old_file_unscorable)

      {_, {:error, :unscorable}} ->
        handle_unscorable(new_file, old_file, media_item, :new_file_unscorable)
    end
  end

  # Task 10 review finding 3: the triggering conditions here (a quality
  # profile that got deleted or blanked out between grab and finalize, or a
  # media file with neither a media_item nor an episode) are permanent, not
  # transient — retrying the job five times and letting Oban discard it
  # would strand `supersedes_media_file_id` forever, leaving BOTH files
  # active and untrashed: a silent duplicate copy the library treats as two
  # ordinary files. This is a terminal outcome like the other three: clear
  # the pointer so the file settles as an ordinary import, and surface it as
  # an operator-visible `job.failed` event (Mydia.Events.job_failed/3)
  # rather than relying on someone noticing later.
  defp handle_unscorable(new_file, old_file, media_item, reason) do
    Logger.error(
      "Cannot finalize upgrade: unable to score the comparison — clearing the pointer and " <>
        "leaving both files as ordinary imports",
      media_file_id: new_file.id,
      superseded_media_file_id: old_file.id,
      reason: reason
    )

    Events.job_failed(
      "upgrade_finalize",
      "Could not score an automatic-upgrade comparison; left both files untouched",
      %{
        "media_file_id" => new_file.id,
        "superseded_media_file_id" => old_file.id,
        "media_item_id" => media_item && media_item.id,
        "reason" => to_string(reason)
      }
    )

    with {:ok, _} <- clear_pointer(new_file) do
      {:ok, :unscorable}
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

  # Blacklist *before* clearing the pointer, not after (whole-branch review
  # finding 3). With the old order, a failed clear_pointer left the file
  # trashed with its pointer intact, and Oban's retry hit the trashed-new-file
  # guard in finalize_upgrade/1, returning {:ok, :noop} before blacklisting
  # ever ran. The lying release stayed grabbable and the whole
  # grab/import/reject cycle - a full download's bandwidth and disk - repeated
  # daily. Blacklists.add/5 upserts on (indexer, guid), so it is idempotent
  # and the reorder cannot make the data-safety story worse.
  defp apply_rejection(new_file, old_file, media_item, comparison) do
    with {:ok, trashed_new} <- Library.trash_media_file(new_file) do
      blacklisted? = blacklist_release(trashed_new)

      with {:ok, _new_file} <- clear_pointer(trashed_new) do
        Events.upgrade_rejected(trashed_new, old_file, media_item, comparison, blacklisted?)
        {:ok, :rejected}
      end
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

  # Blacklisting a rejected upgrade's release is not optional for a single
  # release: without it, the next sweep grabs the exact same lying release,
  # imports it, rejects it, and repeats forever. The (indexer, guid) pair is
  # reached by tracing new_file's
  # `metadata.extra["imported_from_download_id"]` (written by
  # `Mydia.Jobs.MediaImport` on every import) back to the `Download` row,
  # which always carries `indexer` and a `metadata["guid"]` — real, or a
  # deterministic fallback synthesized by
  # `Mydia.Downloads.Queue.build_download_metadata/1` when the indexer
  # didn't supply one. A failure to resolve either is logged loudly rather
  # than silently skipped, but does not block the rejection outcome:
  # blocking the whole job retrying forever on a permanently-missing
  # download record would be worse than a logged gap in the blacklist.
  #
  # Returns whether the release was actually blacklisted, so the activity
  # trail can say which of the two rejections this was.
  defp blacklist_release(new_file) do
    with download_id when is_binary(download_id) <- download_id_for(new_file),
         %Download{} = download <- Repo.get(Download, download_id) do
      maybe_blacklist_download(new_file, download)
    else
      _ ->
        Logger.error(
          "Could not blacklist rejected upgrade release: no traceable (indexer, guid) " <>
            "for the originating download",
          media_file_id: new_file.id
        )

        false
    end
  end

  # Whole-branch review finding 5: a rejection means one of two very
  # different things.
  #
  # For a single-episode or movie grab it means the release lied about its
  # contents, and blacklisting is the only thing that stops the sweep
  # re-grabbing it tomorrow.
  #
  # For a season pack it very often means nothing of the sort. By this
  # feature's own design an already-above-cutoff episode inside a grabbed
  # pack is *supposed* to fail the gate and have the pack's copy discarded,
  # so a pack that legitimately upgraded eight of ten episodes would be
  # blacklisted because the other two were already good enough. And
  # `reject_blacklisted/2` consults that blacklist on every search path, so
  # the release would also become permanently unavailable to the ordinary
  # missing-episode season search. Skip it: a pack that really is bad
  # simply fails the gate again, which costs a re-download rather than
  # permanently burning a good release.
  defp maybe_blacklist_download(new_file, %Download{} = download) do
    if season_pack?(download) do
      Logger.info(
        "Not blacklisting a season pack whose per-episode copy lost the upgrade comparison: " <>
          "a pack can legitimately upgrade some episodes and not others",
        media_file_id: new_file.id,
        download_id: download.id
      )

      false
    else
      do_blacklist(new_file, download)
    end
  end

  defp season_pack?(%Download{metadata: metadata}) when is_map(metadata),
    do: metadata["season_pack"] == true

  defp season_pack?(%Download{}), do: false

  defp do_blacklist(new_file, %Download{} = download) do
    with guid when is_binary(guid) and guid != "" <- get_in(download.metadata || %{}, ["guid"]),
         indexer when is_binary(indexer) and indexer != "" <- download.indexer do
      case Blacklists.add(indexer, guid, download.title || "Unknown release", "upgrade_rejected") do
        {:ok, _row} ->
          true

        {:error, changeset} ->
          Logger.error("Failed to blacklist rejected upgrade release",
            media_file_id: new_file.id,
            download_id: download.id,
            errors: inspect(changeset.errors)
          )

          false
      end
    else
      _ ->
        Logger.error(
          "Could not blacklist rejected upgrade release: no traceable (indexer, guid) " <>
            "for the originating download",
          media_file_id: new_file.id
        )

        false
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
