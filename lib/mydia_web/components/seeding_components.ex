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
  def removal_warning_text(download) do
    case SeedingGoal.for_download(download) do
      %SeedingGoal{met?: false} = goal ->
        Enum.join(
          [requirement(goal), standing(goal), gettext("Removing it now risks a hit-and-run.")],
          " "
        )

      _none_or_met ->
        nil
    end
  end

  @doc ~s(The chip's text, such as "0.42 / 1.0 · 1d / 3d" or "Seeding goal met".)
  @spec chip_text(SeedingGoal.t()) :: String.t()
  def chip_text(%SeedingGoal{met?: true}), do: gettext("Seeding goal met")

  def chip_text(%SeedingGoal{required_ratio: nil, required_seed_time: nil}),
    do: gettext("Private, kept seeding")

  def chip_text(%SeedingGoal{} = goal) do
    [
      goal.required_ratio &&
        "#{format_ratio(goal.ratio)} / #{format_required_ratio(goal.required_ratio)}",
      goal.required_seed_time &&
        "#{format_time(goal.seeding_time)} / #{format_time(goal.required_seed_time)}"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp chip_title(%SeedingGoal{met?: true} = goal),
    do: gettext("%{tracker}'s seeding goal is met", tracker: tracker(goal))

  defp chip_title(goal),
    do:
      gettext("Kept in the download client until %{tracker}'s seeding goal is met",
        tracker: tracker(goal)
      )

  defp requirement(%SeedingGoal{required_ratio: nil, required_seed_time: nil} = goal),
    do:
      gettext("%{tracker} is a private tracker and its seeding rules are unknown.",
        tracker: tracker(goal)
      )

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

  defp format_ratio(ratio) when is_number(ratio) and ratio > 0,
    do: :erlang.float_to_binary(ratio * 1.0, decimals: 2)

  defp format_ratio(_ratio), do: "0.00"

  defp format_required_ratio(ratio), do: :erlang.float_to_binary(ratio * 1.0, [:short])

  defp format_time(nil), do: "?"

  # Days, hours and minutes, leaving out empty parts, so a 90 minute goal
  # reads "1h 30m" rather than rounding down to "1h". Only seconds are dropped.
  defp format_time(seconds) do
    [
      {div(seconds, 86_400), fn n -> gettext("%{count}d", count: n) end},
      {div(rem(seconds, 86_400), 3600), fn n -> gettext("%{count}h", count: n) end},
      {div(rem(seconds, 3600), 60), fn n -> gettext("%{count}m", count: n) end}
    ]
    |> Enum.reject(fn {count, _label} -> count == 0 end)
    |> Enum.map_join(" ", fn {count, label} -> label.(count) end)
    |> case do
      "" -> gettext("%{count}m", count: 0)
      text -> text
    end
  end
end
