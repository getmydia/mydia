defmodule Mydia.SmartSpace.Evaluator do
  @moduledoc """
  Decides which watched TV seasons or episodes Smart Space may trash.

  Pure: no Repo, no config reads, no clock. The caller passes `now` (for the
  grace clock) and `today` (for "has it aired"). Every rule here errs on the
  side of keeping media: anything unknown, missing or malformed makes the
  affected unit ineligible rather than eligible.

  The rules, from the "Eligibility" section of
  `design/specs/2026-11-27-smart-space-design.md`:

    * A show's effective rule is its `"custom"` override, nothing when the
      override is `"off"`, and otherwise the global rule when it is enabled.
    * Required users: `all_started` is every user with any watch record on
      the show (none means nothing in the show is eligible); `selected` is
      every selected user, started or not; `any` needs a single watcher.
    * An episode is done when every required user has a watched record with
      a `last_watched_at`. `done_at` is the latest of those (under `any`, the
      earliest watched record).
    * An episode has aired when it has an `air_date` on or before `today`.
    * Season unit: every episode in the season must have aired; those with
      files must be done; `done_at` is the latest of theirs. A monitored
      episode without files is not done (it is still wanted), so it holds the
      season; only file-less episodes that are already unmonitored are
      skipped.
    * Episode unit: an aired, done episode with files.
    * `eligible_at = done_at + grace_days`, returned when `eligible_at <= now`.
    * An episode's files include a multi-episode file linked to it through
      `media_file_episodes`, so the second episode of an `S01E09E10` file is
      not file-less. Such a file is trashed only when every episode it covers
      is in some cleanup of the same evaluation; otherwise it is held back and
      the episodes it covers leave their cleanups (they stay monitored). Each
      file lands in exactly one cleanup, the earliest eligible, which also
      lists every episode the file covers (so an episode can appear in two
      cleanups), and a cleanup left without files is dropped.
    * Never: season 0, anything under a keep at its level or above (an
      episode keep holds its whole season under the season unit), a unit
      without live files, a unit containing an in-flight episode, or any unit
      of an in-flight show.
  """

  alias Mydia.SmartSpace.{Cleanup, Inputs}
  alias Mydia.SmartSpace.Inputs.{Episode, FileRef, Global, OverrideRule, Show}

  @units ~w(season episode)
  @policies ~w(all_started any selected)
  @seconds_per_day 86_400

  @type rule :: %{unit: String.t(), grace_days: non_neg_integer()}

  @doc """
  Every unit eligible for trashing at `now`, sorted by `eligible_at`
  ascending. `today` decides which episodes have aired.
  """
  @spec eligible(Inputs.t(), DateTime.t(), Date.t()) :: [Cleanup.t()]
  def eligible(%Inputs{selected_user_ids: :misconfigured}, _now, _today), do: []

  def eligible(%Inputs{global: %Global{watched_by: policy}} = inputs, now, today)
      when policy in @policies do
    inputs.shows
    |> Enum.flat_map(&show_cleanups(inputs, &1, now, today))
    |> Enum.sort_by(&{&1.media_item_id, &1.season_number, &1.episode_ids})
    |> Enum.sort_by(& &1.eligible_at, DateTime)
    |> settle_files()
  end

  def eligible(%Inputs{}, _now, _today), do: []

  @doc """
  The rule that applies to `show`: its custom override, or the global rule
  when it inherits and the global rule is enabled. `nil` means skip the show.
  A custom override without a valid unit and grace is skipped too.
  """
  @spec effective_rule(Inputs.t(), Show.t()) :: rule() | nil
  def effective_rule(%Inputs{global: global}, %Show{override: override}) do
    case override do
      %OverrideRule{mode: "custom"} -> valid_rule(override)
      %OverrideRule{mode: "off"} -> nil
      %OverrideRule{mode: "inherit"} -> global_rule(global)
      nil -> global_rule(global)
      _unknown -> nil
    end
  end

  defp global_rule(%Global{enabled: true} = global), do: valid_rule(global)
  defp global_rule(_global), do: nil

  defp valid_rule(%{unit: unit, grace_days: grace})
       when unit in @units and is_integer(grace) and grace >= 0,
       do: %{unit: unit, grace_days: grace}

  defp valid_rule(_rule), do: nil

  # -- per show ---------------------------------------------------------------

  defp show_cleanups(_inputs, %Show{in_flight_show?: true}, _now, _today), do: []

  defp show_cleanups(inputs, %Show{} = show, now, today) do
    with %{} = rule <- effective_rule(inputs, show),
         false <- show_kept?(show),
         {:ok, required} <- required_users(inputs, show) do
      done = done_index(required, show.watches)
      ctx = %{show: show, rule: rule, done: done, now: now, today: today}

      show.episodes
      |> Enum.reject(&(&1.season_number == 0 or is_nil(&1.season_number)))
      |> candidates(rule.unit, ctx)
    else
      _ -> []
    end
  end

  defp show_kept?(%Show{keeps: keeps}), do: Enum.any?(keeps, &(keep_scope(&1) == :show))

  # The scope a keep covers. Anything that is not exactly a season keep (a
  # season number, no episode) or an episode keep (an episode id, no season)
  # is treated as a show keep, so a malformed keep holds the whole show.
  defp keep_scope(%{level: :season, season_number: s, episode_id: nil}) when is_integer(s),
    do: {:season, s}

  defp keep_scope(%{level: :episode, episode_id: id, season_number: nil}) when is_binary(id),
    do: {:episode, id}

  defp keep_scope(_keep), do: :show

  # `{:ok, users}` with a non-empty list of required user ids, `{:ok, :any}`,
  # or `:none` when nobody can satisfy the policy.
  defp required_users(%Inputs{global: %Global{watched_by: "any"}}, _show), do: {:ok, :any}

  defp required_users(%Inputs{global: %Global{watched_by: "all_started"}}, show) do
    show.watches |> Enum.map(& &1.user_id) |> Enum.uniq() |> non_empty()
  end

  defp required_users(
         %Inputs{global: %Global{watched_by: "selected"}, selected_user_ids: ids},
         _show
       )
       when is_list(ids),
       do: ids |> Enum.uniq() |> non_empty()

  defp required_users(_inputs, _show), do: :none

  defp non_empty([]), do: :none
  defp non_empty(users), do: {:ok, users}

  # -- done ---------------------------------------------------------------------

  # Map of episode_id => done_at for every done episode.
  defp done_index(:any, watches) do
    watches
    |> Enum.filter(& &1.watched)
    |> Enum.group_by(& &1.episode_id)
    |> Enum.flat_map(fn {episode_id, records} ->
      case timestamps(records) do
        {:ok, times} -> [{episode_id, Enum.min(times, DateTime)}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  defp done_index(required, watches) when is_list(required) do
    by_episode = Enum.group_by(watches, & &1.episode_id)

    by_episode
    |> Enum.flat_map(fn {episode_id, records} ->
      case episode_done_at(required, records) do
        {:ok, done_at} -> [{episode_id, done_at}]
        :error -> []
      end
    end)
    |> Map.new()
  end

  # Every required user must be done; done_at is the latest user done_at.
  defp episode_done_at(required, records) do
    by_user = Enum.group_by(records, & &1.user_id)

    Enum.reduce_while(required, {:ok, nil}, fn user, {:ok, latest} ->
      case user_done_at(Map.get(by_user, user, [])) do
        {:ok, at} -> {:cont, {:ok, later(latest, at)}}
        :error -> {:halt, :error}
      end
    end)
  end

  # A user is done when they have a watched record and every watched record
  # of theirs carries a timestamp. Their done_at is the latest timestamp on
  # any of their records, so an in-progress rewatch extends the grace.
  defp user_done_at(records) do
    watched = Enum.filter(records, & &1.watched)

    with [_ | _] <- watched,
         {:ok, _} <- timestamps(watched) do
      records
      |> Enum.map(& &1.last_watched_at)
      |> Enum.reject(&is_nil/1)
      |> Enum.max(DateTime)
      |> then(&{:ok, &1})
    else
      _ -> :error
    end
  end

  defp timestamps(records) do
    times = Enum.map(records, & &1.last_watched_at)
    if times != [] and Enum.all?(times, &match?(%DateTime{}, &1)), do: {:ok, times}, else: :error
  end

  defp later(nil, at), do: at
  defp later(a, b), do: if(DateTime.compare(a, b) == :lt, do: b, else: a)

  # -- units ----------------------------------------------------------------

  defp candidates(episodes, "episode", ctx) do
    Enum.flat_map(episodes, fn episode ->
      with false <- episode.in_flight?,
           false <- episode_kept?(ctx.show, episode),
           true <- aired?(episode, ctx.today),
           [_ | _] <- episode.files,
           %DateTime{} = done_at <- Map.get(ctx.done, episode.id),
           {:ok, cleanup} <-
             build(ctx, :episode, episode.season_number, {[episode], [episode]}, done_at) do
        [cleanup]
      else
        _ -> []
      end
    end)
  end

  defp candidates(episodes, "season", ctx) do
    episodes
    |> Enum.group_by(& &1.season_number)
    |> Enum.flat_map(fn {season, season_episodes} ->
      case season_cleanup(ctx, season, season_episodes) do
        {:ok, cleanup} -> [cleanup]
        :error -> []
      end
    end)
  end

  defp season_cleanup(ctx, season, episodes) do
    with_files = Enum.filter(episodes, &(&1.files != []))

    with false <- Enum.any?(episodes, & &1.in_flight?),
         false <- Enum.any?(episodes, &episode_kept?(ctx.show, &1)),
         true <- Enum.all?(episodes, &aired?(&1, ctx.today)),
         false <- Enum.any?(episodes, &wanted_without_files?/1),
         [_ | _] <- with_files,
         {:ok, done_at} <- season_done_at(ctx.done, with_files) do
      # Every episode of the season is affected (so the job unmonitors the
      # file-less ones too); only those with files contribute files.
      build(ctx, :season, season, {episodes, with_files}, done_at)
    else
      _ -> :error
    end
  end

  defp wanted_without_files?(%Episode{files: [], monitored: monitored}), do: monitored != false
  defp wanted_without_files?(%Episode{}), do: false

  defp season_done_at(done, episodes) do
    Enum.reduce_while(episodes, {:ok, nil}, fn episode, {:ok, latest} ->
      case Map.get(done, episode.id) do
        %DateTime{} = at -> {:cont, {:ok, later(latest, at)}}
        nil -> {:halt, :error}
      end
    end)
  end

  # A keep covers its own level and everything below it. Under the season
  # unit an episode keep also holds its whole season back.
  defp episode_kept?(%Show{keeps: keeps}, %Episode{} = episode) do
    Enum.any?(keeps, fn keep ->
      case keep_scope(keep) do
        :show -> true
        {:season, s} -> s == episode.season_number
        {:episode, id} -> id == episode.id
      end
    end)
  end

  defp aired?(%Episode{air_date: %Date{} = date}, today), do: Date.compare(date, today) != :gt
  defp aired?(_episode, _today), do: false

  defp build(ctx, unit, season, {episodes, file_episodes}, done_at) do
    eligible_at = DateTime.add(done_at, ctx.rule.grace_days * @seconds_per_day, :second)

    if DateTime.compare(eligible_at, ctx.now) != :gt do
      cleanup = %Cleanup{
        media_item_id: ctx.show.media_item_id,
        title: ctx.show.title,
        unit: unit,
        season_number: season,
        episode_ids: episodes |> Enum.sort_by(& &1.episode_number) |> Enum.map(& &1.id),
        eligible_at: eligible_at
      }

      {:ok,
       put_files(cleanup, file_episodes |> Enum.flat_map(& &1.files) |> Enum.uniq_by(& &1.id))}
    else
      :error
    end
  end

  defp put_files(%Cleanup{} = cleanup, files) do
    %{
      cleanup
      | files: files,
        file_ids: Enum.map(files, & &1.id),
        bytes: files |> Enum.map(&(&1.size || 0)) |> Enum.sum()
    }
  end

  # -- files shared between episodes -------------------------------------------

  # A file is trashed only when every episode it covers is in some cleanup of
  # this evaluation. One that is not is held back, and the episodes it covers
  # leave their cleanups. That can strand another file on one of those
  # episodes, so repeat until nothing more is held. Each loop removes at least
  # one file, so it terminates.
  defp settle_files(cleanups) do
    covered = cleanups |> Enum.flat_map(& &1.episode_ids) |> MapSet.new()

    held =
      for %Cleanup{files: files} <- cleanups,
          %FileRef{} = file <- files,
          not Enum.all?(file.episode_ids, &MapSet.member?(covered, &1)),
          uniq: true,
          do: file

    if held == [] do
      assign_files_once(cleanups)
    else
      held_ids = MapSet.new(held, & &1.id)
      held_episodes = held |> Enum.flat_map(& &1.episode_ids) |> MapSet.new()

      cleanups
      |> Enum.map(&release(&1, held_ids, held_episodes))
      |> settle_files()
    end
  end

  defp release(%Cleanup{} = cleanup, held_ids, held_episodes) do
    %{
      cleanup
      | episode_ids: Enum.reject(cleanup.episode_ids, &MapSet.member?(held_episodes, &1))
    }
    |> put_files(Enum.reject(cleanup.files, &MapSet.member?(held_ids, &1.id)))
  end

  # Cleanups arrive in eligibility order. A file listed by several goes to the
  # first, so its bytes count once, and that cleanup also takes every episode
  # the file covers: otherwise an episode whose own cleanup ends up without
  # files would lose its file yet stay monitored. An episode may then be listed
  # by more than one cleanup (a later one may still trash another version of
  # it); unmonitoring twice is harmless, and the job's cap keeps or skips
  # cleanups that share an episode together. A cleanup left without files is
  # dropped; any episode only it listed is file-less and already unmonitored.
  # A kept cleanup always lists at least the episodes its own files cover.
  defp assign_files_once(cleanups) do
    {kept, _seen} = Enum.reduce(cleanups, {[], MapSet.new()}, &claim/2)
    Enum.reverse(kept)
  end

  defp claim(cleanup, {acc, seen}) do
    case Enum.reject(cleanup.files, &MapSet.member?(seen, &1.id)) do
      [] ->
        {acc, seen}

      files ->
        episode_ids =
          Enum.uniq(cleanup.episode_ids ++ Enum.flat_map(files, & &1.episode_ids))

        seen = Enum.reduce(files, seen, &MapSet.put(&2, &1.id))
        {[put_files(%{cleanup | episode_ids: episode_ids}, files) | acc], seen}
    end
  end
end
