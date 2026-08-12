defmodule MydiaWeb.AdminDashboardLive.ComponentsTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Streaming.SessionSampler.Sample
  alias MydiaWeb.AdminDashboardLive.Components

  describe "bandwidth_chart/1" do
    test "renders an empty state with fewer than two samples" do
      html = render_component(&Components.bandwidth_chart/1, samples: [], unmeasured_count: 0)

      assert html =~ "bandwidth-chart-empty"
      refute html =~ "<path"
    end

    test "renders one band per session once there is a window" do
      samples = [
        %Sample{at: ~U[2026-08-12 10:00:00Z], sessions: %{"a" => 2.0}, unmeasured_count: 0},
        %Sample{
          at: ~U[2026-08-12 10:00:05Z],
          sessions: %{"a" => 2.0, "b" => 1.0},
          unmeasured_count: 0
        }
      ]

      html =
        render_component(&Components.bandwidth_chart/1, samples: samples, unmeasured_count: 0)

      assert html =~ "bandwidth-chart"
      assert html =~ "<path"
    end

    test "a session keeps its color when another session ends" do
      # Recolor-on-filter regression. stacked_bands/3 sorts keys, so index-based
      # fills would repaint "b" the moment "a" stops. The chart redraws every 5
      # seconds, so this would be constant and very visible.
      both = [
        %Sample{
          at: ~U[2026-08-12 10:00:00Z],
          sessions: %{"a" => 2.0, "b" => 1.0},
          unmeasured_count: 0
        },
        %Sample{
          at: ~U[2026-08-12 10:00:05Z],
          sessions: %{"a" => 2.0, "b" => 1.0},
          unmeasured_count: 0
        }
      ]

      only_b = [
        %Sample{at: ~U[2026-08-12 10:00:10Z], sessions: %{"b" => 1.0}, unmeasured_count: 0},
        %Sample{at: ~U[2026-08-12 10:00:15Z], sessions: %{"b" => 1.0}, unmeasured_count: 0}
      ]

      with_both =
        render_component(&Components.bandwidth_chart/1, samples: both, unmeasured_count: 0)

      with_only_b =
        render_component(&Components.bandwidth_chart/1, samples: only_b, unmeasured_count: 0)

      assert Components.series_fill("b") =~ "fill-"
      assert with_both =~ Components.series_fill("b")
      assert with_only_b =~ Components.series_fill("b")
    end

    test "draws a legend once there are two series" do
      samples = [
        %Sample{
          at: ~U[2026-08-12 10:00:00Z],
          sessions: %{"a" => 2.0, "b" => 1.0},
          unmeasured_count: 0
        },
        %Sample{
          at: ~U[2026-08-12 10:00:05Z],
          sessions: %{"a" => 2.0, "b" => 1.0},
          unmeasured_count: 0
        }
      ]

      html =
        render_component(&Components.bandwidth_chart/1, samples: samples, unmeasured_count: 0)

      assert html =~ "bandwidth-chart-legend"
    end

    test "discloses unmeasured sessions" do
      samples = [
        %Sample{at: ~U[2026-08-12 10:00:00Z], sessions: %{"a" => 2.0}, unmeasured_count: 2},
        %Sample{at: ~U[2026-08-12 10:00:05Z], sessions: %{"a" => 2.0}, unmeasured_count: 2}
      ]

      html =
        render_component(&Components.bandwidth_chart/1, samples: samples, unmeasured_count: 2)

      assert html =~ "unmeasured"
    end
  end

  describe "plays_chart/1" do
    test "renders an empty state when every day is zero" do
      days = for i <- 0..6, do: %{date: Date.add(~D[2026-08-12], -i), movies: 0, episodes: 0}

      html = render_component(&Components.plays_chart/1, days: days)

      assert html =~ "plays-chart-empty"
    end

    test "renders a bar per day when there is data" do
      days = [
        %{date: ~D[2026-08-11], movies: 2, episodes: 1},
        %{date: ~D[2026-08-12], movies: 0, episodes: 3}
      ]

      html = render_component(&Components.plays_chart/1, days: days)

      assert html =~ "plays-chart"
      assert html =~ "<rect"
    end
  end

  describe "recent_watch_card/1" do
    # Task 1 fixed episode titles but could not test the rendered result: the
    # card was private to AdminSystemLive.Components, reachable only through a
    # full LiveView mount. It becomes public here, so pin the behaviour now.
    test "an episode row renders its show title, not Unknown Media" do
      show = Mydia.MediaFixtures.media_item_fixture(%{type: "tv_show", title: "The Expanse"})

      episode =
        Mydia.MediaFixtures.episode_fixture(%{
          media_item_id: show.id,
          season_number: 2,
          episode_number: 5
        })

      user = Mydia.AccountsFixtures.user_fixture()

      {:ok, _} =
        Mydia.Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 300,
          duration_seconds: 2700
        })

      [progress] = Mydia.Playback.list_recent_history(limit: 1)

      html = render_component(&Components.recent_watch_card/1, progress: progress)

      assert html =~ "The Expanse - S02E05"
      refute html =~ "Unknown Media"
    end

    test "a movie row renders its title" do
      movie = Mydia.MediaFixtures.media_item_fixture(%{type: "movie", title: "Arrival"})
      user = Mydia.AccountsFixtures.user_fixture()

      {:ok, _} =
        Mydia.Playback.save_progress(user.id, [media_item_id: movie.id], %{
          position_seconds: 300,
          duration_seconds: 6900
        })

      [progress] = Mydia.Playback.list_recent_history(limit: 1)

      html = render_component(&Components.recent_watch_card/1, progress: progress)

      assert html =~ "Arrival"
    end
  end

  describe "kpi_row/1" do
    test "renders all four figures" do
      html =
        render_component(&Components.kpi_row/1,
          active_streams: 3,
          total_mbps: 12.5,
          plays_today: 4,
          plays_week: 21,
          unmeasured_count: 0
        )

      assert html =~ "kpi-active-streams"
      assert html =~ "kpi-bandwidth"
      assert html =~ "kpi-plays-today"
      assert html =~ "kpi-plays-week"
    end
  end
end
