defmodule MydiaWeb.MediaLive.Show.EpisodeFilePathTest do
  @moduledoc """
  An episode file whose location cannot be resolved must not take down the
  media detail page. These two call sites render on page load, so a single
  orphaned row used to be fatal before the page was even interacted with.
  """
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Library.MediaFile
  alias Mydia.Media.Episode
  alias Mydia.Settings.LibraryPath
  alias MydiaWeb.MediaLive.Show.Components
  alias MydiaWeb.MediaLive.Show.Helpers

  defp resolvable_file do
    %MediaFile{
      id: "mf-1",
      path: nil,
      relative_path: "Season 01/S01E01 - Pilot.mkv",
      library_path: %LibraryPath{path: "/media/series"},
      resolution: "1080p"
    }
  end

  # The backfill migration leaves files outside every library path with no
  # relative_path and no library_path_id.
  defp orphaned_file do
    %MediaFile{
      id: "mf-2",
      path: nil,
      relative_path: nil,
      library_path: nil,
      resolution: nil
    }
  end

  defp file_row_assigns(file) do
    [
      file: file,
      episode: %Episode{id: "ep-1", monitored: true, media_files: [file]},
      playback_enabled: false,
      transcode_jobs: []
    ]
  end

  # The filename also appears in the title attribute, so asserting on the whole
  # document would pass even if the visible text went missing.
  defp visible_filename(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("span.font-mono")
    |> LazyHTML.text()
  end

  describe "episode_file_row/1" do
    test "names a resolvable file" do
      html = render_component(&Components.episode_file_row/1, file_row_assigns(resolvable_file()))

      assert visible_filename(html) =~ "S01E01 - Pilot.mkv"
      assert html =~ ~s|title="/media/series/Season 01/S01E01 - Pilot.mkv"|
    end

    test "renders an orphaned file instead of crashing the page" do
      html = render_component(&Components.episode_file_row/1, file_row_assigns(orphaned_file()))

      assert visible_filename(html) =~ "Unknown file"
    end
  end

  describe "episode_status_tooltip/1" do
    test "lists a resolvable file by name" do
      episode = %Episode{monitored: true, media_files: [resolvable_file()]}

      assert Helpers.episode_status_tooltip(episode) =~ "S01E01 - Pilot.mkv (1080p)"
    end

    test "tolerates an orphaned file instead of crashing the page" do
      episode = %Episode{monitored: true, media_files: [orphaned_file()]}

      assert Helpers.episode_status_tooltip(episode) =~ "Unknown file (?)"
    end
  end
end
