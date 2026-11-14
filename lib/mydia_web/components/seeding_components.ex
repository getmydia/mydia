defmodule MydiaWeb.SeedingComponents do
  @moduledoc """
  A download's progress toward its tracker's seeding goal: the chip on the
  Downloads rows and the hit-and-run warning in manual removal confirms.

  Used by `MydiaWeb.DownloadsLive` and `MydiaWeb.MediaLive.Show`, so not
  globally imported. The rule itself lives in `Mydia.Downloads.SeedingGoal`.
  """
  use MydiaWeb, :html

  alias Mydia.Downloads.SeedingGoal

  attr :id, :string, required: true
  attr :download, :map, required: true, doc: "an enriched download row"

  @doc "The seeding chip, or nothing when no goal applies to the download."
  def seeding_chip(assigns) do
    assigns = assign(assigns, :goal, SeedingGoal.for_download(assigns.download))

    ~H"""
    <span
      :if={@goal}
      id={@id}
      class={[
        "badge badge-sm gap-1 whitespace-nowrap tabular-nums",
        if(@goal.met?, do: "badge-success badge-soft", else: "badge-warning badge-soft")
      ]}
      title={chip_title(@goal)}
    >
      <.icon
        name={if(@goal.met?, do: "hero-check-badge", else: "hero-arrow-up-circle")}
        class="size-3"
      />
      {chip_text(@goal)}
    </span>
    """
  end

  attr :id, :string, default: "seeding-removal-warning"
  attr :download, :map, required: true

  @doc "The hit-and-run warning as an alert, or nothing when removal is safe."
  def removal_warning(assigns) do
    assigns = assign(assigns, :text, removal_warning_text(assigns.download))

    ~H"""
    <p :if={@text} id={@id} role="alert" class="alert alert-warning text-sm mb-4">
      <.icon name="hero-exclamation-triangle" class="size-4 shrink-0" />
      <span>{@text}</span>
    </p>
    """
  end

  @doc """
  A `data-confirm` message: `base`, followed by the hit-and-run warning when
  the download has not met its tracker's seeding goal.
  """
  @spec confirm_text(map(), String.t()) :: String.t()
  def confirm_text(download, base) do
    case removal_warning_text(download) do
      nil -> base
      warning -> base <> "\n\n" <> warning
    end
  end

  @doc """
  Names the tracker, its goal and where the download stands, and says that
  removing now risks a hit-and-run. Nil when no goal applies or it is met.
  """
  @spec removal_warning_text(map()) :: String.t() | nil
  def removal_warning_text(download), do: goal_warning_text(SeedingGoal.for_download(download))

  @doc "The removal warning for an already computed goal. Nil when none or met."
  @spec goal_warning_text(SeedingGoal.t() | nil) :: String.t() | nil
  def goal_warning_text(%SeedingGoal{met?: false} = goal) do
    [
      requirement(goal),
      target_requirement(goal),
      standing(goal),
      gettext("Removing it now risks a hit-and-run.")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  def goal_warning_text(_none_or_met), do: nil

  @doc """
  The chip's text, such as "0.42 / 1.0 · 1d / 3d" or "Seeding goal met". The
  tracker's requirement and the operator's target are separate parts, the
  latter marked "target", e.g. "0.42 / 1.0 · target 0.42 / 2.0".
  """
  @spec chip_text(SeedingGoal.t()) :: String.t()
  def chip_text(%SeedingGoal{met?: true}), do: gettext("Seeding goal met")

  def chip_text(%SeedingGoal{} = goal) do
    case Enum.reject([tracker_chip(goal), target_chip(goal)], &is_nil/1) do
      [] -> gettext("Private, kept seeding")
      parts -> Enum.join(parts, " · ")
    end
  end

  # Private with no known minimum: nothing to count toward, but not nothing.
  defp tracker_chip(%SeedingGoal{required_ratio: nil, required_seed_time: nil} = goal),
    do: if(goal.private? == true, do: gettext("Private, kept seeding"))

  defp tracker_chip(goal),
    do: progress(goal, goal.seeding_time, goal.required_ratio, goal.required_seed_time)

  defp target_chip(%SeedingGoal{target_ratio: nil, target_seed_time: nil}), do: nil

  # The target counts only reported or observed seed time.
  defp target_chip(goal),
    do:
      gettext("target %{progress}",
        progress:
          progress(goal, goal.target_seeding_time, goal.target_ratio, goal.target_seed_time)
      )

  defp progress(goal, seeding_time, required_ratio, required_seed_time) do
    [
      required_ratio &&
        "#{format_ratio(goal.ratio)} / #{format_required_ratio(required_ratio)}",
      required_seed_time &&
        "#{format_time(seeding_time)} / #{format_time(required_seed_time)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  @doc "The chip's tooltip. A row held only by the operator's target names the target."
  @spec chip_title(SeedingGoal.t()) :: String.t()
  def chip_title(%SeedingGoal{} = goal) do
    case {target_only?(goal), goal.met?} do
      {true, true} ->
        gettext("The seeding target is met")

      {true, false} ->
        gettext("Kept in the download client until the seeding target is met")

      {false, true} ->
        gettext("%{tracker}'s seeding goal is met", tracker: tracker(goal))

      {false, false} ->
        gettext("Kept in the download client until %{tracker}'s seeding goal is met",
          tracker: tracker(goal)
        )
    end
  end

  # No tracker requirement (and not a private tracker): only the target applies.
  defp target_only?(%SeedingGoal{} = goal),
    do:
      is_nil(goal.required_ratio) and is_nil(goal.required_seed_time) and
        goal.private? != true and
        not (is_nil(goal.target_ratio) and is_nil(goal.target_seed_time))

  # A target with no tracker terms at all has no tracker sentence.
  defp requirement(%SeedingGoal{required_ratio: nil, required_seed_time: nil} = goal) do
    if goal.private? == true or (is_nil(goal.target_ratio) and is_nil(goal.target_seed_time)) do
      gettext("%{tracker} is a private tracker and its seeding rules are unknown.",
        tracker: tracker(goal)
      )
    end
  end

  defp requirement(%SeedingGoal{required_seed_time: nil} = goal),
    do:
      gettext("%{tracker} requires a ratio of %{ratio}.",
        tracker: tracker(goal),
        ratio: format_required_ratio(goal.required_ratio)
      )

  defp requirement(%SeedingGoal{required_ratio: nil} = goal),
    do:
      gettext("%{tracker} requires %{time} of seeding.",
        tracker: tracker(goal),
        time: format_time(goal.required_seed_time)
      )

  defp requirement(goal),
    do:
      gettext("%{tracker} requires a ratio of %{ratio} or %{time} of seeding.",
        tracker: tracker(goal),
        ratio: format_required_ratio(goal.required_ratio),
        time: format_time(goal.required_seed_time)
      )

  # A met target is not mentioned: only the tracker's minimum is pending.
  defp target_requirement(%SeedingGoal{target_met?: true}), do: nil
  defp target_requirement(%SeedingGoal{target_ratio: nil, target_seed_time: nil}), do: nil

  defp target_requirement(%SeedingGoal{target_seed_time: nil} = goal),
    do:
      gettext("The seeding target of a ratio of %{ratio} is not yet reached.",
        ratio: format_required_ratio(goal.target_ratio)
      )

  defp target_requirement(%SeedingGoal{target_ratio: nil} = goal),
    do:
      gettext("The seeding target of %{time} of seeding is not yet reached.",
        time: format_time(goal.target_seed_time)
      )

  defp target_requirement(goal),
    do:
      gettext(
        "The seeding target of a ratio of %{ratio} or %{time} of seeding is not yet reached.",
        ratio: format_required_ratio(goal.target_ratio),
        time: format_time(goal.target_seed_time)
      )

  defp standing(%SeedingGoal{ratio: nil, seeding_time: nil}),
    do: gettext("Mydia cannot read this download's ratio or seed time right now.")

  defp standing(%SeedingGoal{ratio: nil} = goal),
    do:
      gettext("This download has seeded for %{time}; its ratio is unknown.",
        time: format_time(goal.seeding_time)
      )

  defp standing(%SeedingGoal{seeding_time: nil} = goal),
    do: gettext("This download is at a ratio of %{ratio}.", ratio: format_ratio(goal.ratio))

  defp standing(goal),
    do:
      gettext("This download is at a ratio of %{ratio} after %{time} of seeding.",
        ratio: format_ratio(goal.ratio),
        time: format_time(goal.seeding_time)
      )

  defp tracker(%SeedingGoal{tracker: tracker}) when is_binary(tracker) and tracker != "",
    do: tracker

  defp tracker(_goal), do: gettext("The tracker")

  # Truncated, not rounded: an unmet 0.999 must not read as a reached 1.00.
  defp format_ratio(ratio) when is_number(ratio) and ratio > 0,
    do: :erlang.float_to_binary(trunc(Float.round(ratio * 100.0, 6)) / 100, decimals: 2)

  defp format_ratio(nil), do: "?"
  defp format_ratio(_zero_or_negative), do: "0.00"

  defp format_required_ratio(ratio), do: :erlang.float_to_binary(ratio * 1.0, [:short])

  defp format_time(nil), do: "?"

  # Days, hours, minutes and seconds, leaving out empty parts, so a 90 minute
  # goal reads "1h 30m" and a 61 second one "1m 1s", never a rounded value.
  defp format_time(0), do: gettext("%{count}s", count: 0)

  defp format_time(seconds) do
    [
      {div(seconds, 86_400), fn n -> gettext("%{count}d", count: n) end},
      {div(rem(seconds, 86_400), 3600), fn n -> gettext("%{count}h", count: n) end},
      {div(rem(seconds, 3600), 60), fn n -> gettext("%{count}m", count: n) end},
      {rem(seconds, 60), fn n -> gettext("%{count}s", count: n) end}
    ]
    |> Enum.reject(fn {count, _label} -> count == 0 end)
    |> Enum.map_join(" ", fn {count, label} -> label.(count) end)
  end
end
