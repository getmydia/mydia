defmodule MydiaWeb.AdminDashboardLive.ChartGeometry do
  @moduledoc """
  Pure geometry for the dashboard's plays chart.

  Kept apart from the component module so the maths is unit-testable without
  rendering, and so neither file grows past the project's size limit. Nothing
  here touches assigns, sockets, or the database.

  All coordinates are in an unscaled user space that the SVG `viewBox` maps to
  whatever the container is; callers pass nominal width and height.
  """

  @doc """
  One column per day, each carrying stacked movie and episode segments.

  `y` and `height` are in the unscaled user space described above. `label` is
  the axis tick, rendered only for a subset of columns by the caller.
  """
  @spec bar_columns([map()], number(), number()) :: [map()]
  def bar_columns([], _width, _height), do: []

  def bar_columns(days, width, height) do
    peak =
      days
      |> Enum.map(&(&1.movies + &1.episodes))
      |> Enum.max(fn -> 0 end)
      |> max(1)

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
end
