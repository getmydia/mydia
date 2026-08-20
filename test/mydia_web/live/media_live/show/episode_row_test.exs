defmodule MydiaWeb.MediaLive.Show.EpisodeRowTest do
  @moduledoc """
  The episode row's controls are icon-only, so their DOM ids are the only stable
  handle a test has.

  `episode_rows/1` is private, so these drive the public `season_section/1` with
  `expanded?: true` instead — the same `render_component/2` approach
  `season_collapse_test.exs` already uses for `season_header/1`. That path
  touches neither the database nor a connection, so this file is `async: true`;
  the `async: false` Postgres-sandbox rule is only for connected LiveView tests.
  """
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Media.AvailabilityStatus
  alias MydiaWeb.MediaLive.Show.Helpers

  describe "episode_status_label/1" do
    test "names the state" do
      status = %AvailabilityStatus{state: :missing, monitored: true}

      assert Helpers.episode_status_label(status) == "Missing"
    end

    test "marks an unmonitored item so the faded chip explains itself" do
      status = %AvailabilityStatus{state: :downloaded, monitored: false}

      assert Helpers.episode_status_label(status) == "Downloaded · Not monitored"
    end
  end

  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias MydiaWeb.MediaLive.Show.SeasonComponents

  # library_path: nil rather than an unloaded association — MediaFile.absolute_path/1
  # logs a warning for the unloaded case, once per file per render, which would
  # bury the real output of every test in this file.
  defp media_file(attrs \\ []) do
    struct!(
      %MediaFile{
        id: "file-1",
        resolution: "1080p",
        library_path: nil,
        relative_path: "S01E01.mkv"
      },
      attrs
    )
  end

  defp episode(attrs \\ []) do
    struct!(
      %Episode{
        id: "ep-1",
        season_number: 1,
        episode_number: 1,
        title: "Pilot",
        monitored: true,
        air_date: ~D[2024-01-01],
        media_files: [],
        downloads: []
      },
      attrs
    )
  end

  defp render_season(episodes, opts \\ []) do
    render_component(&SeasonComponents.season_section/1,
      season_number: 1,
      episodes: episodes,
      expanded?: true,
      expanded_episodes: MapSet.new(),
      playback_enabled: Keyword.get(opts, :playback_enabled, true),
      segment_detection_available: false
    )
  end

  # LazyHTML.filter/2 matches root nodes only. Every control here is nested, so
  # this must be query/2.
  defp query(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  end

  defp has_selector?(html, selector), do: html |> query(selector) |> Enum.any?()

  describe "episode row controls" do
    test "every action carries a stable DOM id" do
      html = render_season([episode(media_files: [media_file()])])

      for suffix <- ~w(status play auto-search manual-search monitor) do
        assert has_selector?(html, "#episode-ep-1-#{suffix}"),
               "expected #episode-ep-1-#{suffix} to render"
      end
    end

    test "play is a link when the episode has a file" do
      html = render_season([episode(media_files: [media_file()])])

      assert has_selector?(html, "a#episode-ep-1-play")
      refute has_selector?(html, "button#episode-ep-1-play")
    end

    test "play is a disabled button when the episode has no file" do
      html = render_season([episode(media_files: [])])

      assert has_selector?(html, "button#episode-ep-1-play[disabled]")
      refute has_selector?(html, "a#episode-ep-1-play")
    end

    test "the play slot is absent entirely when playback is off, for every row" do
      html = render_season([episode(media_files: [media_file()])], playback_enabled: false)

      refute has_selector?(html, "#episode-ep-1-play")
      assert has_selector?(html, "#episode-ep-1-auto-search")
    end

    test "the status chip names the state instead of relying on its tooltip" do
      html = render_season([episode(air_date: ~D[2024-01-01], media_files: [])])

      label = html |> query("#episode-ep-1-status") |> LazyHTML.text()

      assert label =~ "Missing"
    end

    test "the four actions sit in one join group" do
      html = render_season([episode(media_files: [media_file()])])

      assert html |> query(".join > .join-item") |> Enum.count() >= 4
    end
  end
end
