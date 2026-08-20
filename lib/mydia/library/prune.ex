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

  alias Mydia.Events
  alias Mydia.Library
  alias Mydia.Library.MediaFile
  alias Mydia.Library.Prune.{Decision, Eligibility, Group, Grouping, Ranker}

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

  defp trash_all(files) do
    Enum.reduce(files, {[], []}, fn file, {ok, bad} ->
      case Library.trash_media_file(file) do
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
