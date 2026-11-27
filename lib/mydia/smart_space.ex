defmodule Mydia.SmartSpace do
  @moduledoc """
  Smart Space: trashes TV that every required viewer has finished.

  `upcoming/1` previews what will become eligible; `run/1` does the work.
  Eligibility lives in `Mydia.SmartSpace.Evaluator` (pure) fed by
  `Mydia.SmartSpace.Loader`. This module only applies the verdicts: it moves
  files to the trash with `reason: :smart_space`, unmonitors the episodes whose
  files all moved, and records events. It never deletes anything.

  A season that was due is listed with every episode, including episodes
  without files, so unmonitoring covers the whole season.

  Per cleanup the order is: unmonitor its episodes, trash its files, then
  monitor again every episode a failed file covers (only those this run
  unmonitored), so the next run retries them. A crash between the steps
  leaves files live on unmonitored episodes; eligibility does not look at
  `monitored` for an episode with files, so the next run finishes the job.
  """

  import Ecto.Query

  require Logger

  alias Mydia.Events
  alias Mydia.Library
  alias Mydia.Media.Episode
  alias Mydia.Media.Monitoring
  alias Mydia.Repo
  alias Mydia.SmartSpace.{Cleanup, Evaluator, Loader}

  @default_cap 200
  @default_within_days 30
  @run_types ["smart_space.run", "smart_space.cleanup"]

  @type summary :: %{
          cleanups: non_neg_integer(),
          files: non_neg_integer(),
          failed: non_neg_integer(),
          bytes: non_neg_integer(),
          capped?: boolean()
        }

  @doc """
  Cleanups that will be eligible within `opts[:within_days]` (default 30),
  with `eligible_at` set. Narrow to one show with `opts[:media_item_id]`.

  Only the grace clock looks ahead: airing is judged against today, so a
  season whose last episode has not aired yet is never previewed.
  """
  @spec upcoming(keyword()) :: [Cleanup.t()]
  def upcoming(opts \\ []) do
    within = Keyword.get(opts, :within_days, @default_within_days)
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)

    opts
    |> Keyword.take([:media_item_id, :config])
    |> Loader.load()
    |> Evaluator.eligible(DateTime.add(now, within, :day), DateTime.to_date(now))
  end

  @doc """
  Trashes everything eligible now, up to `opts[:cap]` files (default 200).

  Returns `{:error, :misconfigured}` (and records a warning event) when the
  `selected` policy names users that do not exist.
  """
  @spec run(keyword()) :: {:ok, summary()} | {:error, :misconfigured}
  def run(opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    cap = Keyword.get(opts, :cap, @default_cap)
    inputs = opts |> Keyword.take([:config]) |> Loader.load()

    cond do
      inputs.shows == [] ->
        {:ok, empty_summary()}

      inputs.selected_user_ids == :misconfigured ->
        record(%{type: "smart_space.misconfigured", severity: :warning, metadata: %{}})
        {:error, :misconfigured}

      true ->
        {chosen, skipped, oversized} = inputs |> evaluate(now) |> apply_cap(cap)
        capped? = skipped != []
        log_capped(skipped, oversized, cap)
        run = %{unmonitored: MapSet.new(), held: MapSet.new()}

        {summary, _run} =
          Enum.reduce(chosen, {%{empty_summary() | capped?: capped?}, run}, &apply_cleanup/2)

        record(%{type: "smart_space.run", metadata: summary})
        {:ok, summary}
    end
  end

  @doc "When Smart Space last ran or trashed something, or `nil`."
  @spec last_run_at() :: DateTime.t() | nil
  def last_run_at do
    Repo.one(
      from e in Mydia.Events.Event,
        where: e.type in ^@run_types,
        select: max(e.inserted_at)
    )
  end

  defp evaluate(inputs, now), do: Evaluator.eligible(inputs, now, DateTime.to_date(now))

  defp empty_summary, do: %{cleanups: 0, files: 0, failed: 0, bytes: 0, capped?: false}

  # Cleanups arrive sorted by eligible_at. Cleanups that share an episode (a
  # multi-episode file on one, another version of the same episode on the
  # other) form a group that is taken or skipped whole: taking only the first
  # would unmonitor an episode whose other file stays live. A group that does
  # not fit in what is left of the cap is skipped, never split; later, smaller
  # ones may still fit. Chosen cleanups keep their order. A group larger than
  # the cap on its own can never fit, so it is skipped on every run; those are
  # counted as oversized. Returns {chosen, skipped, oversized_groups}.
  defp apply_cap(cleanups, cap) do
    indexed = Enum.with_index(cleanups)
    groups = episode_groups(indexed)
    oversized = Enum.count(groups, &(group_files(&1) > cap))

    {taken, _total} =
      Enum.reduce(groups, {MapSet.new(), 0}, fn group, {taken, total} ->
        count = group_files(group)

        if total + count <= cap,
          do:
            {Enum.reduce(group, taken, fn {_c, i}, acc -> MapSet.put(acc, i) end), total + count},
          else: {taken, total}
      end)

    {chosen, skipped} = Enum.split_with(indexed, fn {_c, i} -> MapSet.member?(taken, i) end)
    {Enum.map(chosen, &elem(&1, 0)), Enum.map(skipped, &elem(&1, 0)), oversized}
  end

  defp group_files(group),
    do: group |> Enum.map(fn {c, _i} -> length(c.file_ids) end) |> Enum.sum()

  # Connected groups of {cleanup, index} sharing an episode, ordered by their
  # earliest member.
  defp episode_groups(indexed) do
    indexed
    |> Enum.reduce([], fn {cleanup, _i} = member, groups ->
      episodes = MapSet.new(cleanup.episode_ids)
      {touching, rest} = Enum.split_with(groups, &(not MapSet.disjoint?(&1.episodes, episodes)))
      [Enum.reduce(touching, %{members: [member], episodes: episodes}, &merge_group/2) | rest]
    end)
    |> Enum.map(fn group -> Enum.sort_by(group.members, &elem(&1, 1)) end)
    |> Enum.sort_by(fn [{_c, i} | _] -> i end)
  end

  defp merge_group(group, acc) do
    %{members: group.members ++ acc.members, episodes: MapSet.union(group.episodes, acc.episodes)}
  end

  defp log_capped([], _oversized, _cap), do: :ok

  defp log_capped(skipped, oversized, cap) do
    # An oversized group never fits, so it is skipped on every run and needs
    # the season's "Delete season files" action instead.
    Logger.warning(
      "Smart Space hit its per-run cap; skipped cleanups wait for a later run, " <>
        "oversized ones are never taken automatically",
      cap: cap,
      skipped_cleanups: length(skipped),
      skipped_files: skipped |> Enum.map(&length(&1.file_ids)) |> Enum.sum(),
      oversized_groups: oversized
    )
  end

  # `run` tracks, across the whole run, the episodes this run unmonitored and
  # those a failed file holds. A held episode is never unmonitored by a later
  # cleanup that shares it.
  defp apply_cleanup(%Cleanup{} = cleanup, {summary, run}) do
    unmonitored =
      cleanup.episode_ids
      |> Enum.reject(&MapSet.member?(run.held, &1))
      |> unmonitor()
      |> MapSet.union(run.unmonitored)

    {:ok, %{trashed: trashed, failed: failed, bytes: bytes}} =
      Library.trash_media_files(cleanup.file_ids, reason: :smart_space)

    held = failed_coverage(cleanup, failed)
    set_monitored(MapSet.intersection(held, unmonitored), true)

    run = %{
      unmonitored: MapSet.difference(unmonitored, held),
      held: MapSet.union(run.held, held)
    }

    {record_cleanup(cleanup, summary, trashed, failed, bytes), run}
  end

  # Unmonitors the episodes and returns the ids that were monitored before.
  defp unmonitor([]), do: MapSet.new()

  defp unmonitor(ids) do
    rows = Repo.all(from e in Episode, where: e.id in ^ids, select: {e.id, e.monitored})
    set_monitored(Enum.map(rows, &elem(&1, 0)), false)
    for {id, monitored} <- rows, monitored != false, into: MapSet.new(), do: id
  end

  defp set_monitored(ids, monitored) do
    ids |> Enum.map(&%Episode{id: &1}) |> Monitoring.set_episodes_monitored(monitored)
  end

  # Every episode covered by a file that failed to move.
  defp failed_coverage(%Cleanup{files: files}, failed) do
    by_id = Map.new(files, &{&1.id, &1.episode_ids})

    for {file, _reason} <- failed,
        id <- Map.get(by_id, file.id, [file.episode_id]),
        not is_nil(id),
        into: MapSet.new(),
        do: id
  end

  defp record_cleanup(cleanup, summary, trashed, failed, bytes) do
    if trashed != [] do
      record(%{
        type: "smart_space.cleanup",
        resource_type: "media_item",
        resource_id: cleanup.media_item_id,
        metadata: %{
          season_number: cleanup.season_number,
          episode_count: length(cleanup.episode_ids),
          file_count: length(trashed),
          bytes: bytes
        }
      })
    end

    %{
      summary
      | cleanups: summary.cleanups + if(trashed != [], do: 1, else: 0),
        files: summary.files + length(trashed),
        failed: summary.failed + length(failed),
        bytes: summary.bytes + bytes
    }
  end

  defp record(attrs) do
    base = %{
      category: "media",
      actor_type: :job,
      actor_id: "smart_space",
      severity: :info
    }

    case Events.create_event(Map.merge(base, attrs)) do
      {:ok, _} -> :ok
      {:error, cs} -> Logger.warning("Smart Space event not recorded", errors: inspect(cs.errors))
    end
  end
end
