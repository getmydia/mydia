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
end
