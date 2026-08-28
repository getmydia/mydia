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

  # An episode's file, in the shape the database actually stores it:
  # episode_id set, media_item_id nil. `file/2` alone leaves episode_id nil,
  # which is a *show-level* file and would not exercise the split below.
  defp episode_file(id, relative_path) do
    %{file(id, relative_path) | episode_id: "ep-#{id}"}
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

    # This card shows the item's *own* files. An episode's file already renders
    # under its episode in `episode_rows/1`/`episode_file_row/1`, so merging
    # `all_media_files/1` in here listed every episode file a second time, with
    # no episode label, under a heading that reads as show-level. On the
    # reference deployment that was 49 of 53 shows rendering a card that was
    # 100% episode files -- Silo showed 29 unlabelled filenames, every one of
    # them already listed above under its own episode.
    test "does not render files that belong to an episode" do
      media_item = %{
        media_files: [],
        episodes: [
          %{media_files: [episode_file("mf-ep-1", "Breaking Bad/Season 01/S01E01.mkv")]},
          %{media_files: [episode_file("mf-ep-2", "Breaking Bad/Season 01/S01E02.mkv")]}
        ]
      }

      html = section_html(media_item)

      refute html =~ "media-files-section"
      refute html =~ "S01E01.mkv"
      refute html =~ "S01E02.mkv"
    end

    # media_item_id set, episode_id nil. `Mydia.Jobs.MediaImport`'s catch-all
    # fallback creates exactly this when a TV download's episode cannot be
    # resolved, and no episode row will ever render it. This card is its only
    # surface, which is why the fix filters by episode_id rather than skipping
    # `all_media_files/1` for shows outright.
    test "renders a TV show's own file that belongs to no episode" do
      media_item = %{
        media_files: [file("mf-show", "Breaking Bad/unmatched-release.mkv")],
        episodes: [
          %{media_files: [episode_file("mf-ep-1", "Breaking Bad/Season 01/S01E01.mkv")]}
        ]
      }

      html = section_html(media_item)

      assert html =~ "media-files-section"
      assert html =~ "unmatched-release.mkv"
      assert html =~ ~s|phx-value-file-id="mf-show"|
      refute html =~ "S01E01.mkv"
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

      html = section_html(%{media_files: [broken], episodes: []})

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
