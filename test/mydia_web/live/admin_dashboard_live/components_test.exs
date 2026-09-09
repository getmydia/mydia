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

  describe "now_playing_card/1" do
    alias Mydia.Accounts.User
    alias Mydia.Streaming.ActiveSession

    defp session(attrs) do
      struct(
        %ActiveSession{
          session_id: "s1",
          user: %User{username: "alex", email: "alex@example.com"},
          media_title: "Arrival",
          media_type: :movie,
          mode: :direct,
          started_at: ~U[2026-08-12 10:00:00Z],
          ready: true,
          bitrate_bps: 8_000_000
        },
        attrs
      )
    end

    test "renders the poster when the session has one" do
      html =
        render_component(&Components.now_playing_card/1,
          session: session(%{poster_path: "/p.jpg"})
        )

      assert html =~ "Poster"
      assert html =~ "Arrival"
    end

    test "falls back to an initials avatar when there is no poster" do
      html =
        render_component(&Components.now_playing_card/1, session: session(%{poster_path: nil}))

      refute html =~ "alt=\"Poster\""
      # Rendered lowercase; the `uppercase` class does the visual work.
      assert html =~ "avatar placeholder"
      assert html =~ "al"
    end

    test "renders a scrubber only when position and duration are both known" do
      with_progress =
        render_component(&Components.now_playing_card/1,
          session: session(%{position_seconds: 300, duration_seconds: 6900})
        )

      without_progress =
        render_component(&Components.now_playing_card/1,
          session: session(%{position_seconds: nil, duration_seconds: nil})
        )

      assert with_progress =~ "<progress"
      refute without_progress =~ "<progress"
    end

    test "labels direct play and transcode distinctly" do
      direct =
        render_component(&Components.now_playing_card/1, session: session(%{plan: nil}))

      transcode_plan = %Mydia.Streaming.StreamPlan{
        video: %Mydia.Streaming.StreamPlan.Video{
          action: :encode,
          from_codec: "h264",
          to_codec: "h264"
        },
        audio: %Mydia.Streaming.StreamPlan.Audio{
          action: :copy,
          from_codec: "aac",
          to_codec: "aac"
        },
        container: :hls_ts
      }

      transcode =
        render_component(&Components.now_playing_card/1,
          session: session(%{plan: transcode_plan})
        )

      assert direct =~ "Direct Play"
      assert transcode =~ "Transcode"
    end
  end

  describe "now_playing_card/1 badges" do
    alias Mydia.Streaming.ActiveSession
    alias Mydia.Streaming.StreamPlan

    defp card(plan) do
      session = %ActiveSession{
        session_id: "s1",
        # A plain map, not a User struct: user_label/1 matches on %{username: _},
        # so the card does not need the schema and this test does not couple to it.
        user: %{username: "dana"},
        media_title: "The Lantern Quarter",
        media_type: :movie,
        episode_info: nil,
        mode: :copy,
        started_at: ~U[2026-09-08 10:00:00Z],
        ready: true,
        media_file_id: "file-1",
        bitrate_bps: 4_200_000,
        plan: plan
      }

      render_component(&Components.now_playing_card/1, session: session)
    end

    test "a capped HLS_COPY session reads Transcode, not Direct Play" do
      # The reported bug, exactly. The client asked for HLS_COPY and the
      # session's mode is :copy, but the 480p rung's bitrate cap makes FFmpeg
      # re-encode. The badge must follow FFmpeg, not the request.
      plan = %StreamPlan{
        video: %StreamPlan.Video{
          action: :encode,
          from_codec: "hevc",
          to_codec: "h264",
          from_width: 1920,
          from_height: 1080,
          to_width: 854,
          to_height: 480,
          tier: :full_hardware
        },
        audio: %StreamPlan.Audio{
          action: :encode,
          from_codec: "eac3",
          to_codec: "aac",
          language: "eng"
        },
        container: :hls_ts,
        max_bitrate_kbps: 1500
      }

      html = card(plan)

      assert html =~ "Transcode"
      refute html =~ "Direct Play"
      assert html =~ "1920x1080"
      assert html =~ "854x480"
      assert html =~ "hevc"
      assert html =~ "h264"
    end

    test "a video-copy stream reads Remux even when audio is converted" do
      # Keying the badge off "either stream encodes" would call a routine
      # audio conversion a full transcode. Video is the expensive stream and
      # the one an operator scans for.
      plan = %StreamPlan{
        video: %StreamPlan.Video{
          action: :copy,
          from_codec: "h264",
          to_codec: "h264",
          from_width: 1920,
          from_height: 1080,
          to_width: 1920,
          to_height: 1080
        },
        audio: %StreamPlan.Audio{
          action: :encode,
          from_codec: "eac3",
          to_codec: "aac",
          language: "eng"
        },
        container: :fmp4
      }

      html = card(plan)

      assert html =~ "Remux"
      refute html =~ "Transcode"
      refute html =~ "Direct Play"
    end

    test "no plan reads Direct Play" do
      html = card(nil)

      assert html =~ "Direct Play"
      refute html =~ "Transcode"
    end

    test "an unknown source height omits the resolution row" do
      plan = %StreamPlan{
        video: %StreamPlan.Video{
          action: :encode,
          from_codec: "hevc",
          to_codec: "h264",
          from_width: nil,
          from_height: nil,
          to_width: nil,
          to_height: nil,
          tier: :software
        },
        audio: %StreamPlan.Audio{action: :copy, from_codec: "aac", to_codec: "aac"},
        container: :hls_ts
      }

      html = card(plan)

      assert html =~ "Transcode"
      refute html =~ "now-playing-resolution"
    end
  end
end
