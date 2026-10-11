defmodule Mydia.ImportCandidates.LocalShows do
  @moduledoc false

  import Ecto.Query

  alias Mydia.Accounts.Scope
  alias Mydia.ImportCandidates.{AcceptQueue, Review, Store}
  alias Mydia.Library.{ImportCandidate, ImportRun, MediaFile}
  alias Mydia.Media
  alias Mydia.Media.Episode
  alias Mydia.Repo

  @doc """
  Clears the derived scan state for one library path: every undismissed
  candidate, plus finished import-run history.

  Dismissed candidates are preserved -- clearing is "re-match from scratch",
  not "discard every decision a human already made". Active runs are refused
  so their coordinator cannot recreate candidates while the clear is in
  progress.
  """
  @spec clear_for_library(binary()) ::
          {:ok, %{candidates: non_neg_integer()}} | {:error, :active_run}
  def clear_for_library(library_path_id) do
    result =
      Repo.transaction(fn ->
        active_statuses = ImportRun.active_statuses()

        if Repo.exists?(
             from(r in ImportRun,
               where: r.library_path_id == ^library_path_id and r.status in ^active_statuses
             )
           ) do
          Repo.rollback(:active_run)
        end

        {candidate_count, _} =
          ImportCandidate
          |> where([c], c.library_path_id == ^library_path_id and is_nil(c.dismissed_at))
          |> Repo.delete_all()

        ImportRun
        |> where([r], r.library_path_id == ^library_path_id)
        |> Repo.delete_all()

        %{candidates: candidate_count}
      end)

    with {:ok, counts} <- result do
      Store.broadcast(library_path_id)
      {:ok, counts}
    end
  end

  @doc """
  Creates a local show from an anchor's folder name, for media no provider
  carries.

  There is no provider match for `CandidatePromotion` to enrich from, so this
  links members itself: it creates the show (no episode auto-fetch --
  episodes come from each candidate's own parsed season/episode numbers),
  inserts an owned `MediaFile` for every candidate whose numbering resolved,
  and deletes each one it successfully linked, all in one transaction.

  A candidate with no parsed episode number is left alone -- undismissed,
  visible, and still part of whatever the anchor's next read computes -- since
  there is nothing here that could number it.

  A repeat call against the same anchor is refused with
  `{:error, :already_created}` rather than minting a second, emptier show:
  every candidate this function leaves behind (the unnumbered leftovers) is
  stamped `provider_type: "local"` with `provider_id` set to the created
  item's id, so the anchor still exists to look at (it now bands as
  `:needs_attention`, never `:no_match`, via the same local carve-out
  `Review.band/1` and `Review.group_query/2` already give a provider-matched
  local group),
  but this function's own precondition -- every remaining candidate already
  local-marked -- is what a second click actually hits.

  Scoped to the anchor's *pending* subset (`queued_op IS NULL`) via
  `AcceptQueue.load_pending_members/2`, not its full membership: a scan can insert a
  pending row under an anchor whose import is already queued for accept, and
  that queued row carries a real provider match this function must not
  overwrite with a generic local identity, nor delete out from under the
  drain that is about to promote it. The queued row is left untouched --
  `queued_op`, its provider fields, and its existence all survive -- and
  continues to be promoted normally.
  """
  @spec create_local_show(binary(), String.t()) :: {:ok, Media.MediaItem.t()} | {:error, term()}
  def create_local_show(library_path_id, anchor_key) do
    Repo.transaction(fn -> create_local_show_transaction(library_path_id, anchor_key) end)
    |> case do
      {:ok, result} -> result
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_local_show_transaction(library_path_id, anchor_key) do
    case AcceptQueue.load_pending_members(library_path_id, anchor_key) do
      [] ->
        {:error, :not_found}

      candidates ->
        if Enum.all?(candidates, &(&1.provider_type == "local")) do
          {:error, :already_created}
        else
          do_create_local_show(library_path_id, anchor_key, candidates)
        end
    end
  end

  defp do_create_local_show(library_path_id, anchor_key, candidates) do
    {title, year} = title_and_year(anchor_key)

    case Media.create_media_item(
           Scope.system(),
           %{title: title, year: year, type: "tv_show", monitored: false},
           skip_episode_refresh: true
         ) do
      {:ok, item} ->
        Enum.each(candidates, &link_local_candidate(&1, item))
        mark_leftover_candidates_local(library_path_id, anchor_key, item)
        Store.broadcast(library_path_id)
        {:ok, item}

      {:error, reason} ->
        Repo.rollback(reason)
    end
  end

  # Every candidate `link_local_candidate/2` successfully linked is already
  # deleted by the time this runs; what remains among the *pending* subset is
  # exactly the unnumbered leftovers `create_local_show/2`'s doc promises to
  # leave visible. Stamping them here (not before creating `item`, since
  # `provider_id` needs its id) is what makes a second call against the same
  # anchor see an all-local-marked pending group and refuse rather than
  # minting a second show.
  #
  # Scoped to `is_nil(queued_op)`, matching
  # `AcceptQueue.load_pending_members/2`: `Review.for_anchor/3` alone would also overwrite any row already queued for
  # accept/rematch under this anchor, discarding its real provider identity
  # in favour of this synthetic local one.
  defp mark_leftover_candidates_local(library_path_id, anchor_key, item) do
    now = Store.now()

    ImportCandidate
    |> Review.for_anchor(library_path_id, anchor_key)
    |> where([c], is_nil(c.queued_op))
    |> Repo.update_all(set: [provider_type: "local", provider_id: item.id, updated_at: now])
  end

  # `anchor_key` is already normalized (lowercased, punctuation and any
  # `(YYYY)` year stripped) by `Mydia.Library.PathAnchor.normalize/1`, so
  # -- unlike parsing a year out of the original folder text -- there is no
  # year left to recover here. `Review.humanize/1` title-cases the key back into
  # something presentable; the year is accepted as lost.
  defp title_and_year(anchor_key), do: {Review.humanize(anchor_key), nil}

  defp link_local_candidate(%ImportCandidate{} = candidate, item) do
    with %{} = parsed <- candidate.parsed_info,
         season when is_integer(season) <- Map.get(parsed, "season"),
         [number | _] <- Map.get(parsed, "episodes") || [] do
      episode =
        Repo.get_by(Episode,
          media_item_id: item.id,
          season_number: season,
          episode_number: number
        ) ||
          create_local_episode(item, season, number, candidate)

      if episode, do: insert_local_file(candidate, episode)
    else
      _ -> :ok
    end
  end

  defp create_local_episode(item, season, number, candidate) do
    case Media.create_episode(%{
           media_item_id: item.id,
           season_number: season,
           episode_number: number,
           title: Path.rootname(Path.basename(candidate.relative_path))
         }) do
      {:ok, episode} -> episode
      {:error, _changeset} -> nil
    end
  end

  defp insert_local_file(candidate, episode) do
    attrs = %{
      episode_id: episode.id,
      library_path_id: candidate.library_path_id,
      relative_path: candidate.relative_path,
      size: candidate.size,
      verified_at: Store.now()
    }

    case %MediaFile{} |> MediaFile.changeset(attrs) |> Repo.insert() do
      {:ok, media_file} ->
        # Episode.media_files reads through media_file_episodes, so a bare
        # episode_id would leave the file invisible on the episode page.
        {:ok, _} = Mydia.Library.ensure_episode_link(media_file)
        Repo.delete(candidate)

      {:error, _changeset} ->
        :ok
    end
  end
end
