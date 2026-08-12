defmodule MydiaWeb.AdminDashboardLive.ChartGeometry do
  @moduledoc """
  Pure geometry for the dashboard's SVG charts.

  Kept apart from the component module so the maths is unit-testable without
  rendering, and so neither file grows past the project's size limit. Nothing
  here touches assigns, sockets, or the database.

  All coordinates are in an unscaled user space that the SVG `viewBox` maps to
  whatever the container is; callers pass nominal width and height.
  """

  alias Mydia.Streaming.SessionSampler.Sample

  # A flat 1 Mbps ceiling for an idle server, so an empty chart still draws a
  # sane axis instead of dividing by zero.
  @min_peak 1.0

  @doc """
  The largest stacked total across the window, never less than #{@min_peak}.
  """
  @spec peak_mbps([Sample.t()]) :: float()
  def peak_mbps(samples) do
    samples
    |> Enum.map(&total/1)
    |> Enum.max(fn -> 0.0 end)
    |> max(@min_peak)
  end

  @doc """
  One closed SVG path per session, stacked bottom-up in a stable key order.

  Sessions come and go, so a key absent from a sample contributes zero at that
  x rather than interrupting the band. Fewer than two samples produces no
  bands, because a single point has no area to fill.
  """
  @spec stacked_bands([Sample.t()], number(), number()) :: [%{key: String.t(), path: String.t()}]
  def stacked_bands(samples, width, height) when length(samples) < 2 do
    _ = {samples, width, height}
    []
  end

  def stacked_bands(samples, width, height) do
    peak = peak_mbps(samples)
    count = length(samples)
    step = width / (count - 1)

    keys =
      samples
      |> Enum.flat_map(&Map.keys(&1.sessions))
      |> Enum.uniq()
      |> Enum.sort()

    # Running baseline per x, so each band sits on the one below it.
    {bands, _baseline} =
      Enum.map_reduce(keys, List.duplicate(0.0, count), fn key, baseline ->
        values = Enum.map(samples, &Map.get(&1.sessions, key, 0.0))
        tops = Enum.zip_with(baseline, values, &(&1 + &2))

        lower = baseline |> Enum.with_index() |> Enum.map(&point(&1, step, peak, height))
        upper = tops |> Enum.with_index() |> Enum.map(&point(&1, step, peak, height))

        path = build_path(upper, Enum.reverse(lower))

        {%{key: key, path: path}, tops}
      end)

    bands
  end

  @doc """
  One column per day, each carrying stacked movie and episode segments.

  `y` and `height` are in the same user space as `stacked_bands/3`. `label` is
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

  defp total(%Sample{sessions: sessions}) do
    sessions |> Map.values() |> Enum.sum()
  end

  defp point({value, index}, step, peak, height) do
    {index * step, height - value / peak * height}
  end

  defp build_path([{x0, y0} | _] = upper, lower) do
    upper_segments = Enum.map_join(upper, " ", fn {x, y} -> "L#{r(x)},#{r(y)}" end)
    lower_segments = Enum.map_join(lower, " ", fn {x, y} -> "L#{r(x)},#{r(y)}" end)

    "M#{r(x0)},#{r(y0)} #{upper_segments} #{lower_segments} Z"
  end

  defp r(number), do: Float.round(number * 1.0, 2)
end
