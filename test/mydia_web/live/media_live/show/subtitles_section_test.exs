defmodule MydiaWeb.MediaLive.Show.SubtitlesSectionTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath
  alias MydiaWeb.MediaLive.Show.Components

  defp section_html(media_file) do
    render_component(&Components.subtitles_section/1,
      media_item: %{media_files: [media_file]},
      media_file_subtitles: %{}
    )
  end

  describe "subtitles_section/1 file naming" do
    test "names the file from library_path + relative_path" do
      media_file = %MediaFile{
        id: "mf-1",
        path: nil,
        relative_path: "The Matrix (1999)/The.Matrix.1999.1080p.BluRay.mkv",
        library_path: %LibraryPath{path: "/media/movies"},
        resolution: "1080p",
        codec: "h264"
      }

      html = section_html(media_file)

      assert html =~ "The.Matrix.1999.1080p.BluRay.mkv"
      assert html =~ ~s|phx-value-media-file-id="mf-1"|
    end

    test "renders a file whose location cannot be resolved instead of crashing" do
      media_file = %MediaFile{
        id: "mf-2",
        path: nil,
        relative_path: nil,
        library_path: nil,
        resolution: nil,
        codec: nil
      }

      html = section_html(media_file)

      # The Search button still renders; one broken row must not take the page down.
      assert html =~ ~s|phx-click="open_subtitle_search"|
      # And the row is labelled rather than left blank.
      assert html =~ "Unknown file"
    end
  end

  describe "media_files_section/1 file naming" do
    defp files_section_html(media_file) do
      render_component(&Components.media_files_section/1,
        media_item: %{media_files: [media_file]},
        refreshing_file_metadata: false,
        transcode_jobs: %{}
      )
    end

    test "shows the full resolved path" do
      media_file = %MediaFile{
        id: "mf-3",
        path: nil,
        relative_path: "The Matrix (1999)/The.Matrix.1999.1080p.BluRay.mkv",
        library_path: %LibraryPath{path: "/media/movies"}
      }

      assert files_section_html(media_file) =~
               "/media/movies/The Matrix (1999)/The.Matrix.1999.1080p.BluRay.mkv"
    end

    test "labels an unresolvable file rather than rendering a blank path" do
      media_file = %MediaFile{id: "mf-4", path: nil, relative_path: nil, library_path: nil}

      assert files_section_html(media_file) =~ "Unknown file"
    end
  end
end
