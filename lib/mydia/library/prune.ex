defmodule Mydia.Library.Prune do
  @moduledoc """
  Removes redundant duplicate copies of an episode or movie.

  Most items holding more than one file are not holding duplicates. They are
  holding misidentified files, one file registered twice, or a feature plus its
  bonus content. `Mydia.Library.Prune.Eligibility` refuses all of those, and
  this module only ever acts on what survives that gate.

  Nothing here runs on a schedule. An operator reviews a plan and confirms it.

  ## Why execute/3 re-verifies

  `execute/3` does not trust the ids it is handed. It rebuilds the plan
  (honoring the same `keepers` overrides the operator's plan was built from)
  and drops any id that is not a current loser of a currently eligible group.
  The page can be minutes stale, a scan can have changed the group underneath
  it, and a caller can reach this function without going through the UI at
  all. The UI is not the security boundary; this function is.
  """

  import Ecto.Query, only: [where: 3]

  alias Mydia.Events
  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Prune.{Decision, Eligibility, Group, Grouping, Ranker}
  alias Mydia.Media.{Episode, MediaItem}
  alias Mydia.Repo

  require Logger

  @type refusal :: {Group.t(), atom(), map()}
  @type plan :: %{decisions: [Decision.t()], refusals: [refusal()]}

  @doc """
  Builds the current plan: what can be pruned, and what was refused and why.

  `keepers` optionally maps a group's `subject_id` to a file id the operator
  chose instead of the ranked keeper.
  """
  @spec plan(%{optional(String.t()) => String.t()}) :: plan()
  def plan(keepers \\ %{}) do
    checked = Enum.map(Grouping.list_groups(), fn group -> {group, Eligibility.check(group)} end)

    decisions =
      for {_group, {:ok, eligible}} <- checked,
          do: Ranker.decide(eligible, Map.get(keepers, eligible.subject_id))

    refusals =
      for {group, {:refused, reason, detail}} <- checked,
          do: {group, reason, detail}

    %{decisions: decisions, refusals: refusals}
  end

  @doc """
  Trashes the given files, after re-verifying that each one is a current loser
  of a currently eligible group.

  `keepers` must be the same override map the operator's plan was built from
  (see `plan/1`). Without it, `execute/3` would silently re-rank every group
  with the default keeper, discarding whatever override the operator chose
  before confirming.

  Returns which files were trashed, which failed to move, and which were
  aborted by re-verification. Partial failure is reported rather than rolled
  back: `Mydia.Library.TrashStore` has already moved bytes by the time a row
  update can fail, so a global rollback would be a lie.
  """
  @spec execute([String.t()], String.t(), %{optional(String.t()) => String.t()}) :: %{
          trashed: [MediaFile.t()],
          failed: [{String.t(), term()}],
          aborted: [{String.t(), atom()}]
        }
  def execute(file_ids, actor_id, keepers \\ %{})
      when is_list(file_ids) and is_binary(actor_id) and is_map(keepers) do
    requested = MapSet.new(file_ids)
    %{decisions: decisions, refusals: refusals} = plan(keepers)

    refused_ids =
      for {group, reason, _detail} <- refusals,
          file <- group.files,
          MapSet.member?(requested, file.id),
          do: {file.id, reason}

    {selected, aborted_keepers} =
      Enum.reduce(decisions, {[], []}, fn %Decision{} = decision, {selected, aborted} ->
        losers = Enum.filter(decision.losers, &MapSet.member?(requested, &1.id))

        aborted =
          if MapSet.member?(requested, decision.keeper.id) do
            [{decision.keeper.id, :would_leave_no_file} | aborted]
          else
            aborted
          end

        {[{decision, losers} | selected], aborted}
      end)

    known_ids =
      decisions
      |> Enum.flat_map(fn d -> [d.keeper.id | Enum.map(d.losers, & &1.id)] end)
      |> MapSet.new()

    unknown =
      for id <- file_ids,
          not MapSet.member?(known_ids, id),
          not List.keymember?(refused_ids, id, 0),
          do: {id, :not_in_any_group}

    {trashed, failed} =
      selected
      |> Enum.reject(fn {_decision, losers} -> losers == [] end)
      |> Enum.reduce({[], []}, fn {decision, losers}, {ok, bad} ->
        {group_ok, group_bad} = trash_all(losers)

        if group_ok != [] do
          Events.files_pruned(decision.keeper, group_ok, decision.group.media_item, actor_id)
        end

        {ok ++ group_ok, bad ++ group_bad}
      end)

    %{trashed: trashed, failed: failed, aborted: refused_ids ++ aborted_keepers ++ unknown}
  end

  @doc """
  Restores files a previous `execute/3` trashed.

  Only rows that are currently trashed are touched. A row can stop being
  trashed between an undo being offered and the operator taking it:
  `Mydia.Jobs.TrashCleanup` can purge it, a library scan can restore it, or
  another admin session can act on it. Restoring a row that is not in the trash
  is not a no-op further down, so the filter belongs here rather than in
  `Mydia.Library.restore_media_file/1`.

  An id matching no row is ignored for the same reason `execute/3` does not
  trust its input: this function is reachable without going through the UI.

  Partial failure is reported rather than rolled back, matching `execute/3`.
  Bytes have already moved by the time a row update can fail, so a global
  rollback would be a lie.
  """
  @spec undo([String.t()], String.t()) :: %{
          restored: [MediaFile.t()],
          failed: [{String.t(), term()}]
        }
  def undo(file_ids, actor_id) when is_list(file_ids) and is_binary(actor_id) do
    files =
      MediaFile
      |> where([mf], mf.id in ^file_ids and not is_nil(mf.trashed_at))
      |> Repo.all()
      |> Repo.preload([:library_path, :media_item, episode: :media_item])

    {restored, failed} =
      Enum.reduce(files, {[], []}, fn file, {ok, bad} ->
        case Library.restore_media_file(file) do
          {:ok, file} ->
            {ok ++ [file], bad}

          {:error, reason} ->
            Logger.error("Prune could not restore a trashed media file",
              media_file_id: file.id,
              reason: inspect(reason)
            )

            {ok, bad ++ [{file.id, reason}]}
        end
      end)

    announce_restored(restored, files, actor_id)

    %{restored: restored, failed: failed}
  end

  # One event per subject (episode or movie), mirroring the per-group shape of
  # the `media_file.pruned` events `execute/3` writes.
  #
  # The grouping key is the file's own subject, not the media item: a show's
  # `media_item` is shared by every one of its episodes, so grouping by media
  # item would fold two different episodes' restored files into one event and
  # silently drop the other.
  #
  # `restored` holds rows returned by `Repo.update/1`, which do not carry the
  # preloads, so both the subject key and the media item are read from the
  # matching row loaded before the restore.
  defp announce_restored(restored, loaded, actor_id) do
    by_id = Map.new(loaded, &{&1.id, &1})

    restored
    |> Enum.map(&Map.fetch!(by_id, &1.id))
    |> Enum.group_by(&subject_key/1)
    |> Enum.each(fn {_key, files} ->
      case media_item_of(hd(files)) do
        nil -> :ok
        media_item -> Events.prune_undone(media_item, files, actor_id)
      end
    end)
  end

  defp subject_key(%MediaFile{episode_id: id}) when not is_nil(id), do: {:episode, id}
  defp subject_key(%MediaFile{media_item_id: id}), do: {:media_item, id}

  # Preloaded by undo/2 as `[:media_item, episode: :media_item]`, so neither
  # clause queries.
  defp media_item_of(%MediaFile{episode: %Episode{media_item: %MediaItem{} = item}}), do: item
  defp media_item_of(%MediaFile{media_item: %MediaItem{} = item}), do: item
  defp media_item_of(%MediaFile{}), do: nil

  defp trash_all(files) do
    Enum.reduce(files, {[], []}, fn file, {ok, bad} ->
      case Library.trash_media_file(file, reason: :pruned) do
        {:ok, trashed} ->
          {ok ++ [trashed], bad}

        {:error, reason} ->
          Logger.error("Prune could not trash media file",
            media_file_id: file.id,
            reason: inspect(reason)
          )

          {ok, bad ++ [{file.id, reason}]}
      end
    end)
  end
end
