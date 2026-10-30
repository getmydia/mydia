defmodule MydiaWeb.AdminDashboardLive.PlaysChartComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias MydiaWeb.AdminDashboardLive.ChartGeometry

  @ranges [7, 30, 90]

  @chart_w 600
  @chart_h 160
  @stack_gap 2

  # @chart_w / @chart_h are the plot's viewBox; the SVG is stretched to the card
  # and the axis labels are HTML placed by percentage around it.

  @doc "The chart ranges, in days, that the picker offers."
  def ranges, do: @ranges

  attr :days, :list, required: true
  attr :range, :integer, required: true

  def plays_chart(assigns) do
    assigns =
      assigns
      |> assign(:columns, ChartGeometry.bar_columns(assigns.days, @chart_w, @chart_h))
      |> assign(:y_ticks, ChartGeometry.y_ticks(assigns.days, @chart_h))
      |> assign(:x_ticks, ChartGeometry.x_ticks(assigns.days, @chart_w))
      |> assign(:chart_w, @chart_w)
      |> assign(:chart_h, @chart_h)
      |> assign(:stack_gap, @stack_gap)
      |> assign(:ranges, @ranges)

    ~H"""
    <.admin_section id="plays" title={pgettext("playback", "Plays")} icon="hero-chart-bar">
      <:actions>
        <.segmented_control
          id="plays-range"
          value={@range}
          event="set_plays_range"
          param="range"
          label={gettext("Plays range")}
        >
          <:option :for={days <- @ranges} value={days} label={"#{days}d"} />
        </.segmented_control>
      </:actions>
      <div id="plays-chart">
        <%!-- Axis labels are HTML, not SVG <text>: the plot is scaled to the
              card, and scaled SVG text shrinks below 12px on a phone. The
              labels sit beside the plot at the same percentages the SVG uses. --%>
        <div class="flex gap-1 pt-2 pr-5">
          <div id="plays-chart-y-axis" class="relative w-8 h-40 shrink-0 text-xs text-base-content/60">
            <span
              :for={tick <- @y_ticks}
              class="absolute right-0 -translate-y-1/2 tabular-nums leading-none"
              style={"top: #{tick.y / @chart_h * 100}%"}
            >{tick.value}</span>
          </div>
          <div class="min-w-0 flex-1">
            <svg
              viewBox={"0 0 #{@chart_w} #{@chart_h}"}
              preserveAspectRatio="none"
              class="block w-full h-40"
              role="group"
              aria-label={gettext("Plays per day")}
            >
              <line
                :for={tick <- @y_ticks}
                x1="0"
                y1={tick.y}
                x2={@chart_w}
                y2={tick.y}
                class="stroke-base-300"
                stroke-width="1"
                vector-effect="non-scaling-stroke"
              />
              <%= for col <- @columns do %>
                <% gap = if col.episodes.height > 0 and col.movies.height > 0, do: @stack_gap, else: 0 %>
                <rect
                  :if={col.episodes.height > 0}
                  x={col.x}
                  y={col.episodes.y}
                  width={col.width}
                  height={max(col.episodes.height - gap / 2, 0)}
                  class="fill-primary"
                />
                <rect
                  :if={col.movies.height > 0}
                  x={col.x}
                  y={col.movies.y + gap / 2}
                  width={col.width}
                  height={max(col.movies.height - gap / 2, 0)}
                  class="fill-secondary"
                />
                <rect x={col.x} y="0" width={col.width} height={@chart_h} fill="transparent">
                  <title>
                    {gettext("%{label}: %{movies}, %{episodes}",
                      label: col.label,
                      movies: ngettext("%{count} movie", "%{count} movies", col.movies.count),
                      episodes: ngettext("%{count} episode", "%{count} episodes", col.episodes.count)
                    )}
                  </title>
                </rect>
              <% end %>
            </svg>
            <div id="plays-chart-x-axis" class="relative h-6 text-xs text-base-content/60">
              <span
                :for={{tick, index} <- Enum.with_index(@x_ticks)}
                class={[
                  "absolute top-1 -translate-x-1/2 whitespace-nowrap leading-none",
                  rem(index, 2) == 1 && "max-sm:hidden"
                ]}
                style={"left: #{tick.x / @chart_w * 100}%"}
              >{tick.label}</span>
            </div>
          </div>
        </div>
        <div id="plays-chart-legend" class="flex flex-wrap gap-3 mt-2">
          <div class="flex items-center gap-1.5 text-xs text-base-content">
            <span class="inline-block w-2.5 h-2.5 rounded-sm bg-primary"></span>
            <span class="opacity-60">{pgettext("tv", "Episodes")}</span>
          </div>
          <div class="flex items-center gap-1.5 text-xs text-base-content">
            <span class="inline-block w-2.5 h-2.5 rounded-sm bg-secondary"></span>
            <span class="opacity-60">{gettext("Movies")}</span>
          </div>
        </div>
      </div>
    </.admin_section>
    """
  end
end
