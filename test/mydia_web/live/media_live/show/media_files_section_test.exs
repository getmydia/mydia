defmodule MydiaWeb.MediaLive.Show.MediaFilesSectionTest do
  # async: false - the refresh_all_file_metadata/2 block added in Step 6 touches
  # the Ecto sandbox from a stub socket, which shares the connection with the
  # test process. That only works in non-async mode on PostgreSQL. The
  # render_component cases below do not hit the database and would be safe
  # either way.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath
  alias MydiaWeb.MediaLive.Show.Components
  alias MydiaWeb.MediaLive.Show.FileEvents
  alias MydiaWeb.MediaLive.Show.Loaders

  defp section_html(media_item) do
    render_component(&Components.media_files_section/1,
      media_item: media_item,
      refreshing_file_metadata: false,
      transcode_jobs: %{}
    )
  end

  defp file(id, relative_path) do
    %MediaFile{
      id: id,
      path: nil,
      relative_path: relative_path,
      library_path: %LibraryPath{path: "/media"},
      resolution: "1080p",
      codec: "h264",
      audio_codec: "eac3",
      size: 4_200_000_000
    }
  end

  defp stub_socket(media_item) do
    %Phoenix.LiveView.Socket{
      assigns: %{__changed__: %{}, flash: %{}, media_item: media_item},
      private: %{live_temp: %{}},
      root_pid: self()
    }
  end

  describe "media_files_section/1" do
    test "renders a movie's own files" do
      media_item = %{
        media_files: [file("mf-1", "The Matrix (1999)/The.Matrix.1999.1080p.mkv")],
        episodes: []
      }

      html = section_html(media_item)

      assert html =~ "The.Matrix.1999.1080p.mkv"
      assert html =~ ~s|phx-value-file-id="mf-1"|
    end

    # A MediaFile belongs to either media_item_id (movies) or episode_id (TV
    # episodes), never both, so media_item.media_files alone is always empty
    # for a TV show. Episode files live at media_item.episodes[].media_files
    # instead; the section must reach into both.
    test "renders files that belong to an episode, not just the item's own" do
      media_item = %{
        media_files: [],
        episodes: [
          %{media_files: [file("mf-ep-1", "Breaking Bad/Season 01/S01E01.mkv")]},
          %{media_files: [file("mf-ep-2", "Breaking Bad/Season 01/S01E02.mkv")]}
        ]
      }

      html = section_html(media_item)

      assert html =~ "media-files-section"
      assert html =~ "S01E01.mkv"
      assert html =~ "S01E02.mkv"
      assert html =~ ~s|phx-value-file-id="mf-ep-1"|
      assert html =~ ~s|phx-value-file-id="mf-ep-2"|
    end

    test "renders nothing when the item has no files anywhere" do
      html = section_html(%{media_files: [], episodes: [%{media_files: []}]})

      refute html =~ "media-files-section"
    end

    test "renders a file whose location cannot be resolved instead of crashing" do
      broken = %MediaFile{
        id: "mf-broken",
        path: nil,
        relative_path: nil,
        library_path: nil,
        resolution: nil,
        codec: nil,
        audio_codec: nil,
        size: nil
      }

      html = section_html(%{media_files: [], episodes: [%{media_files: [broken]}]})

      assert html =~ "Unknown file"
      assert html =~ ~s|phx-value-file-id="mf-broken"|
    end
  end

  describe "refresh_all_file_metadata/2" do
    test "reports nothing to refresh when a TV show really has no files" do
      show = media_item_fixture(%{type: "tv_show"})
      _episode = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

      loaded = Loaders.load_media_item(show.id)

      {:noreply, socket} = FileEvents.refresh_all_file_metadata(%{}, stub_socket(loaded))

      assert socket.assigns.flash["info"] == "No media files to refresh"
    end

    # A MediaFile belongs to either media_item_id or episode_id, never both, so
    # media_item.media_files is empty for a TV show. Reading only that list made
    # this button dead on every show page.
    test "refreshes a TV show whose files hang off its episodes" do
      library_path = library_path_fixture(%{type: "series"})
      show = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: show.id, season_number: 1, episode_number: 1})

      _file =
        media_file_fixture(%{
          episode_id: episode.id,
          library_path_id: library_path.id,
          relative_path: "Show/Season 01/S01E01.mkv"
        })

      loaded = Loaders.load_media_item(show.id)

      # The chain the fix depends on: the preload reaches episode files, and the
      # helper merges them.
      assert [_ | _] = MydiaWeb.MediaLive.Show.Helpers.all_media_files(loaded)

      {:noreply, socket} = FileEvents.refresh_all_file_metadata(%{}, stub_socket(loaded))

      refute socket.assigns.flash["info"] == "No media files to refresh"
      assert socket.assigns.refreshing_file_metadata
    end
  end
end
