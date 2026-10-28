defmodule MydiaWeb.MediaLive.Show.MonitoringMenu do
  @moduledoc """
  The Seasons & Episodes header's one-shot episode monitoring menu.

  Split out of `MydiaWeb.MediaLive.Show.Components`, which is over the module
  size ratchet and cannot grow.
  """

  use MydiaWeb, :html

  import MydiaWeb.MediaLive.Show.Helpers, only: [monitoring_preset_label: 1]

  @doc """
  The preset menu. Each option shows how many episodes it would monitor, from
  `Mydia.Media.monitoring_preview/1` over the episodes already on the page.

  A preset that would monitor nothing is disabled with the reason underneath.
  Picking `:future` on a show with no unaired episodes used to monitor nothing,
  which reads back as "No Episodes" and looked like the click was ignored.
  `:none` stays enabled and shows no count: monitoring nothing is the point of
  it, so its count is always zero.

  The trigger label reads the episode rows back rather than storing what was
  picked, so a manual season toggle shows as Custom instead of going stale.
  """
  attr :episodes, :list, required: true

  def episode_monitoring_menu(assigns) do
    preview = Mydia.Media.monitoring_preview(assigns.episodes)

    assigns =
      assigns
      |> assign(:derived_preset, Mydia.Media.derive_monitoring_preset(assigns.episodes))
      |> assign(
        :options,
        Enum.map(Mydia.Media.monitoring_presets(), fn preset ->
          count = Map.fetch!(preview, preset)
          {preset, monitoring_preset_label(preset), count, preset != :none and count == 0}
        end)
      )

    ~H"""
    <%!-- Native popover plus CSS anchor positioning, as file_actions/1 does.
          At the three-column width #main-column is its own scroll container,
          and a .dropdown-content panel was clipped by it when the header sat
          near the column's bottom edge. The top layer escapes the clip, and
          flip-block opens the panel upward when there is no room below. --%>
    <div>
      <button
        type="button"
        id="episode-monitoring-menu"
        popovertarget="episode-monitoring-menu-panel"
        style="anchor-name:--episode-monitoring-menu"
        class="btn btn-sm btn-ghost gap-1"
      >
        <.icon name="hero-adjustments-horizontal" class="w-4 h-4" />
        <span>{monitoring_preset_label(@derived_preset)}</span>
        <.icon name="hero-chevron-down" class="w-3 h-3 opacity-70" />
      </button>
      <ul
        id="episode-monitoring-menu-panel"
        popover
        class="dropdown dropdown-end menu p-2 shadow-lg bg-base-100 rounded-box w-60 border border-base-300 ms-0 whitespace-normal before:hidden"
        style="position-anchor:--episode-monitoring-menu;position-try-fallbacks:flip-block"
      >
        <li :for={{preset, label, count, disabled?} <- @options} class={disabled? && "menu-disabled"}>
          <button
            type="button"
            id={"episode-monitoring-menu-preset-#{preset}"}
            popovertarget="episode-monitoring-menu-panel"
            popovertargetaction="hide"
            phx-click="apply_episode_monitoring"
            phx-value-preset={preset}
            disabled={disabled?}
            class="flex flex-col items-start gap-0"
          >
            <span>
              {label}
              <span :if={preset != :none} class="text-base-content/50 tabular-nums">({count})</span>
            </span>
            <span
              :if={disabled?}
              id={"episode-monitoring-menu-preset-#{preset}-reason"}
              class="text-xs text-base-content/50"
            >
              {empty_reason(preset)}
            </span>
          </button>
        </li>
      </ul>
    </div>
    """
  end

  defp empty_reason(:all), do: gettext("No episodes")
  defp empty_reason(:missing), do: gettext("No missing episodes")
  defp empty_reason(:existing), do: gettext("No episodes with files")
  defp empty_reason(:future), do: gettext("No upcoming episodes")
end
