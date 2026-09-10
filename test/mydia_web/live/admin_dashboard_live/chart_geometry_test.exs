defmodule MydiaWeb.AdminDashboardLive.ChartGeometryTest do
  use ExUnit.Case, async: true

  alias MydiaWeb.AdminDashboardLive.ChartGeometry

  describe "bar_columns/3" do
    test "returns one column per day with stacked segments" do
      days = [
        %{date: ~D[2026-08-11], movies: 2, episodes: 1},
        %{date: ~D[2026-08-12], movies: 0, episodes: 3}
      ]

      columns = ChartGeometry.bar_columns(days, 600, 160)

      assert length(columns) == 2
      assert Enum.all?(columns, &(&1.movies.height >= 0 and &1.episodes.height >= 0))
      assert Enum.all?(columns, &is_binary(&1.label))
    end

    test "an all-zero window produces zero-height segments and no divide by zero" do
      days = [
        %{date: ~D[2026-08-11], movies: 0, episodes: 0},
        %{date: ~D[2026-08-12], movies: 0, episodes: 0}
      ]

      columns = ChartGeometry.bar_columns(days, 600, 160)

      assert Enum.all?(columns, &(&1.movies.height == 0.0 and &1.episodes.height == 0.0))
    end
  end

  describe "y_ticks/2" do
    test "spans zero to the peak in whole plays" do
      days = [
        %{date: ~D[2026-09-01], movies: 2, episodes: 4},
        %{date: ~D[2026-09-02], movies: 0, episodes: 1}
      ]

      ticks = ChartGeometry.y_ticks(days, 160)

      assert Enum.map(ticks, & &1.value) == [0, 3, 6]
      assert Enum.all?(ticks, &is_integer(&1.value))
    end

    test "deduplicates when the peak is one, so ticks never collide" do
      days = [%{date: ~D[2026-09-01], movies: 1, episodes: 0}]

      assert Enum.map(ChartGeometry.y_ticks(days, 160), & &1.value) == [0, 1]
    end

    test "an all-zero window still produces a usable axis" do
      days = [%{date: ~D[2026-09-01], movies: 0, episodes: 0}]

      ticks = ChartGeometry.y_ticks(days, 160)

      assert Enum.map(ticks, & &1.value) == [0, 1]
      refute Enum.any?(ticks, &(&1.y != &1.y))
    end

    test "the zero tick sits on the baseline and the peak at the top" do
      days = [%{date: ~D[2026-09-01], movies: 0, episodes: 4}]

      ticks = ChartGeometry.y_ticks(days, 160)

      assert List.first(ticks).y == 160.0
      assert List.last(ticks).y == 0.0
    end
  end

  describe "x_ticks/2" do
    test "produces five spaced labels over a thirty-day window" do
      days = for i <- 0..29, do: %{date: Date.add(~D[2026-08-11], i), movies: 0, episodes: 0}

      ticks = ChartGeometry.x_ticks(days, 600)

      assert length(ticks) == 5
      assert Enum.map(ticks, & &1.label) |> Enum.uniq() |> length() == 5
      assert List.first(ticks).label == "Aug 11"
    end

    test "labels every day of a seven-day window" do
      days = for i <- 0..6, do: %{date: Date.add(~D[2026-09-03], i), movies: 0, episodes: 0}

      assert length(ChartGeometry.x_ticks(days, 600)) == 7
    end

    test "stays at five labels over ninety days and keeps them distinct" do
      days = for i <- 0..89, do: %{date: Date.add(~D[2026-06-12], i), movies: 0, episodes: 0}

      ticks = ChartGeometry.x_ticks(days, 600)

      assert length(ticks) == 5
      assert Enum.map(ticks, & &1.label) |> Enum.uniq() |> length() == 5
    end

    test "ticks stay inside the plot width" do
      days = for i <- 0..29, do: %{date: Date.add(~D[2026-08-11], i), movies: 0, episodes: 0}

      assert Enum.all?(ChartGeometry.x_ticks(days, 600), &(&1.x >= 0 and &1.x <= 600))
    end

    test "an empty window produces no ticks" do
      assert ChartGeometry.x_ticks([], 600) == []
      assert ChartGeometry.y_ticks([], 160) == []
    end
  end
end
