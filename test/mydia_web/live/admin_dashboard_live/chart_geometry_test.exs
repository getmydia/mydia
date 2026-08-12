defmodule MydiaWeb.AdminDashboardLive.ChartGeometryTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.SessionSampler.Sample
  alias MydiaWeb.AdminDashboardLive.ChartGeometry

  defp sample(at, sessions), do: %Sample{at: at, sessions: sessions, unmeasured_count: 0}

  describe "peak_mbps/1" do
    test "is the largest stacked total across the window" do
      samples = [
        sample(~U[2026-08-12 10:00:00Z], %{"a" => 2.0}),
        sample(~U[2026-08-12 10:00:05Z], %{"a" => 2.0, "b" => 3.0})
      ]

      assert ChartGeometry.peak_mbps(samples) == 5.0
    end

    test "is never zero, so an empty chart still has a usable axis" do
      assert ChartGeometry.peak_mbps([]) > 0
    end
  end

  describe "stacked_bands/3" do
    test "returns one band per session key ever seen" do
      samples = [
        sample(~U[2026-08-12 10:00:00Z], %{"a" => 2.0}),
        sample(~U[2026-08-12 10:00:05Z], %{"a" => 2.0, "b" => 3.0})
      ]

      bands = ChartGeometry.stacked_bands(samples, 600, 160)

      assert Enum.map(bands, & &1.key) |> Enum.sort() == ["a", "b"]
      assert Enum.all?(bands, &String.starts_with?(&1.path, "M"))
    end

    test "returns no bands for fewer than two samples" do
      assert ChartGeometry.stacked_bands([], 600, 160) == []

      assert ChartGeometry.stacked_bands(
               [sample(~U[2026-08-12 10:00:00Z], %{"a" => 2.0})],
               600,
               160
             ) == []
    end

    test "a session absent from a sample contributes zero rather than breaking the band" do
      samples = [
        sample(~U[2026-08-12 10:00:00Z], %{"a" => 2.0}),
        sample(~U[2026-08-12 10:00:05Z], %{})
      ]

      assert [band] = ChartGeometry.stacked_bands(samples, 600, 160)
      assert band.key == "a"
      refute band.path =~ "NaN"
    end
  end

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
