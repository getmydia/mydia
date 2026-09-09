defmodule MydiaWeb.AdminDashboardLive.ChartGeometry do
  @moduledoc """
  Pure geometry for the dashboard's plays chart.

  Kept apart from the component module so the maths is unit-testable without
  rendering, and so neither file grows past the project's size limit. Nothing
  here touches assigns, sockets, or the database.

  All coordinates are in an unscaled user space that the SVG `viewBox` maps to
  whatever the container is; callers pass nominal width and height.
  """

  # Five is the most labels that stay legible across 600px at 9px type.
  @x_tick_count 5

  @doc """
  One column per day, each carrying stacked movie and episode segments.

  `y` and `height` are in the unscaled user space described above. `label` is
  the axis tick, rendered only for a subset of columns by the caller.
  """
  @spec bar_columns([map()], number(), number()) :: [map()]
  def bar_columns([], _width, _height), do: []

  def bar_columns(days, width, height) do
    peak = peak_plays(days)

    count = length(days)
    slot = width / count
    bar_width = slot * 0.7

    days
    |> Enum.with_index()
    |> Enum.map(fn {day, index} ->
      x = index * slot + (slot - bar_width) / 2

      episodes_height = day.episodes / peak * height
      movies_height = day.movies / peak * height

      %{
        date: day.date,
        label: Calendar.strftime(day.date, "%b %d"),
        x: x,
        width: bar_width,
        total: day.movies + day.episodes,
        # Episodes sit on the baseline, movies stack on top.
        episodes: %{y: height - episodes_height, height: episodes_height, count: day.episodes},
        movies: %{
          y: height - episodes_height - movies_height,
          height: movies_height,
          count: day.movies
        }
      }
    end)
  end

  @doc """
  Y-axis ticks in whole plays: zero, the midpoint, and the peak.

  Deduplicated, because a peak of 1 would otherwise place the midpoint on top
  of the peak. Every tick names a value the chart actually reaches.
  """
  @spec y_ticks([map()], number()) :: [%{value: non_neg_integer(), y: float()}]
  def y_ticks([], _height), do: []

  def y_ticks(days, height) do
    peak = peak_plays(days)

    [0, div(peak + 1, 2), peak]
    |> Enum.uniq()
    |> Enum.map(fn value ->
      %{value: value, y: r(height - value / peak * height)}
    end)
  end

  @doc """
  X-axis ticks, at most #{@x_tick_count} of them, centred on their column.

  Dates carry the day at every range. Month-only labels would repeat across a
  ninety-day window, which reads as a rendering fault rather than a scale.
  """
  @spec x_ticks([map()], number()) :: [%{label: String.t(), x: float()}]
  def x_ticks([], _width), do: []

  def x_ticks(days, width) do
    count = length(days)
    slot = width / count
    stride = max(div(count - 1, @x_tick_count - 1), 1)

    0..(count - 1)//stride
    |> Enum.map(fn index ->
      day = Enum.at(days, index)
      %{label: Calendar.strftime(day.date, "%b %d"), x: r(index * slot + slot / 2)}
    end)
  end

  # Floored at 1 so an all-zero window divides safely and still draws an axis.
  defp peak_plays(days) do
    days
    |> Enum.map(&(&1.movies + &1.episodes))
    |> Enum.max(fn -> 0 end)
    |> max(1)
  end

  defp r(number), do: Float.round(number * 1.0, 2)
end
