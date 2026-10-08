defmodule MydiaWeb.AdminDashboardLive.PlaysChartComponents do
  @moduledoc false
  use MydiaWeb, :html

  alias MydiaWeb.AdminDashboardLive.ChartGeometry

  @ranges [7, 30, 90]

  @chart_w 600
  @chart_h 160
  @stack_gap 2

  # @chart_w / @chart_h are the PLOT box. Padding is added around it in the
  # viewBox so tick labels have somewhere to live without being clipped.
  @pad_l 28
  @pad_t 8
  @pad_b 24

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
      |> assign(:pad_l, @pad_l)
      |> assign(:pad_t, @pad_t)
      |> assign(:view_w, @chart_w + @pad_l)
      |> assign(:view_h, @chart_h + @pad_t + @pad_b)
      |> assign(:ranges, @ranges)

    ~H"""
    <.admin_section id="plays" title="Plays" icon="hero-chart-bar">
      <:actions>
        <.segmented_control
          id="plays-range"
          value={@range}
          event="set_plays_range"
          param="range"
          label="Plays range"
        >
          <:option :for={days <- @ranges} value={days} label={"#{days}d"} />
        </.segmented_control>
      </:actions>
      <div id="plays-chart">
        <svg viewBox={"0 0 #{@view_w} #{@view_h}"} class="w-full h-48">
          <g transform={"translate(#{@pad_l}, #{@pad_t})"}>
            <line
              :for={tick <- @y_ticks}
              x1="0"
              y1={tick.y}
              x2={@chart_w}
              y2={tick.y}
              class="stroke-base-300"
              stroke-width="1"
            />
            <text
              :for={tick <- @y_ticks}
              x="-6"
              y={tick.y + 3}
              text-anchor="end"
              font-size="9"
              class="fill-base-content/60"
              phx-no-format
            >{tick.value}</text>
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
                  {col.label}: {col.movies.count} movies, {col.episodes.count} episodes
                </title>
              </rect>
            <% end %>
            <text
              :for={tick <- @x_ticks}
              x={tick.x}
              y={@chart_h + 16}
              text-anchor="middle"
              font-size="9"
              class="fill-base-content/60"
            >
              {tick.label}
            </text>
          </g>
        </svg>
        <div id="plays-chart-legend" class="flex flex-wrap gap-3 mt-2">
          <div class="flex items-center gap-1.5 text-xs text-base-content">
            <span class="inline-block w-2.5 h-2.5 rounded-sm bg-primary"></span>
            <span class="opacity-60">Episodes</span>
          </div>
          <div class="flex items-center gap-1.5 text-xs text-base-content">
            <span class="inline-block w-2.5 h-2.5 rounded-sm bg-secondary"></span>
            <span class="opacity-60">Movies</span>
          </div>
        </div>
      </div>
    </.admin_section>
    """
  end
end
