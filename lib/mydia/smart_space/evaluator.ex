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
      files must be done; `done_at` is the latest of theirs.
    * Episode unit: an aired, done episode with files.
    * `eligible_at = done_at + grace_days`, returned when `eligible_at <= now`.
    * Never: season 0, anything under a keep at its level or above (an
      episode keep holds its whole season under the season unit), a unit
      without live files, a unit containing an in-flight episode, or any unit
      of an in-flight show.
  """

  alias Mydia.SmartSpace.{Cleanup, Inputs}
  alias Mydia.SmartSpace.Inputs.{Episode, Show}

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

  def eligible(%Inputs{global: %{watched_by: policy}} = inputs, now, today)
      when policy in @policies do
    inputs.shows
    |> Enum.flat_map(&show_cleanups(inputs, &1, now, today))
    |> Enum.sort_by(&{&1.media_item_id, &1.season_number, &1.episode_ids})
    |> Enum.sort_by(& &1.eligible_at, DateTime)
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
      %{mode: "custom"} -> valid_rule(override)
      %{mode: "off"} -> nil
      %{mode: "inherit"} -> global_rule(global)
      nil -> global_rule(global)
      _unknown -> nil
    end
  end

  defp global_rule(%{enabled: true} = global), do: valid_rule(global)
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

  defp show_kept?(%Show{keeps: keeps}), do: Enum.any?(keeps, &(&1.level == :show))

  # `{:ok, users}` with a non-empty list of required user ids, `{:ok, :any}`,
  # or `:none` when nobody can satisfy the policy.
  defp required_users(%Inputs{global: %{watched_by: "any"}}, _show), do: {:ok, :any}

  defp required_users(%Inputs{global: %{watched_by: "all_started"}}, show) do
    show.watches |> Enum.map(& &1.user_id) |> Enum.uniq() |> non_empty()
  end

  defp required_users(%Inputs{global: %{watched_by: "selected"}, selected_user_ids: ids}, _show)
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
           {:ok, cleanup} <- build(ctx, :episode, episode.season_number, [episode], done_at) do
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
         [_ | _] <- with_files,
         {:ok, done_at} <- season_done_at(ctx.done, with_files) do
      build(ctx, :season, season, with_files, done_at)
    else
      _ -> :error
    end
  end

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
    Enum.any?(keeps, fn
      %{level: :show} -> true
      %{level: :season, season_number: s} -> s == episode.season_number
      %{level: :episode, episode_id: id} -> id == episode.id
      _ -> false
    end)
  end

  defp aired?(%Episode{air_date: %Date{} = date}, today), do: Date.compare(date, today) != :gt
  defp aired?(_episode, _today), do: false

  defp build(ctx, unit, season, episodes, done_at) do
    eligible_at = DateTime.add(done_at, ctx.rule.grace_days * @seconds_per_day, :second)

    if DateTime.compare(eligible_at, ctx.now) != :gt do
      files = Enum.flat_map(episodes, & &1.files)

      {:ok,
       %Cleanup{
         media_item_id: ctx.show.media_item_id,
         title: ctx.show.title,
         unit: unit,
         season_number: season,
         episode_ids: episodes |> Enum.sort_by(& &1.episode_number) |> Enum.map(& &1.id),
         file_ids: Enum.map(files, &elem(&1, 0)),
         bytes: files |> Enum.map(&(elem(&1, 1) || 0)) |> Enum.sum(),
         eligible_at: eligible_at
       }}
    else
      :error
    end
  end
end
