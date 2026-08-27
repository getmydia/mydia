defmodule MydiaWeb.MediaLive.Show.SubtitlesSectionTest do
  # async: false - the "offset control" describe block below opens a connected
  # LiveView (`live/2`), which shares the Postgres sandbox connection with the
  # test process. That only works in non-async mode.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath
  alias MydiaWeb.MediaLive.Show.Components

  defp section_html(media_file) do
    render_component(&Components.subtitles_section/1,
      media_item: %{media_files: [media_file]},
      media_file_subtitle_tracks: %{}
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

  describe "offset control" do
    setup %{conn: conn} do
      admin = admin_user_fixture()
      %{conn: log_in_user(conn, admin)}
    end

    defp movie_with_sidecar_subtitle(hash) do
      media_item = media_item_fixture(%{type: "movie"})
      media_file = media_file_fixture(%{media_item_id: media_item.id})

      {:ok, subtitle} =
        %Mydia.Subtitles.Subtitle{}
        |> Mydia.Subtitles.Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          provider: "sidecar",
          origin: "sidecar",
          subtitle_hash: hash,
          file_path: "/tmp/#{hash}.srt",
          format: "srt"
        })
        |> Mydia.Repo.insert()

      {media_item, media_file, subtitle}
    end

    test "renders a stepper for each track and persists a change", %{conn: conn} do
      {media_item, media_file, subtitle} = movie_with_sidecar_subtitle("offset-ui-hash")

      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      assert has_element?(view, "#subtitle-offset-form-#{subtitle.id}")

      view
      |> element("#subtitle-offset-form-#{subtitle.id}")
      |> render_change(%{"offset_ms" => "1500"})

      assert Mydia.Subtitles.TrackSettings.offset_ms(media_file.id, subtitle.id) == 1_500
    end

    test "rejects an out-of-range offset without persisting", %{conn: conn} do
      {media_item, media_file, subtitle} = movie_with_sidecar_subtitle("offset-range-hash")

      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      view
      |> element("#subtitle-offset-form-#{subtitle.id}")
      |> render_change(%{"offset_ms" => "9999999"})

      assert Mydia.Subtitles.TrackSettings.offset_ms(media_file.id, subtitle.id) == 0
    end

    test "the nudge buttons persist an incremented and decremented offset", %{conn: conn} do
      {media_item, media_file, subtitle} = movie_with_sidecar_subtitle("nudge-hash")

      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      render_click(view, "nudge_subtitle_offset", %{
        "media-file-id" => media_file.id,
        "track-ref" => subtitle.id,
        "delta" => "100"
      })

      assert Mydia.Subtitles.TrackSettings.offset_ms(media_file.id, subtitle.id) == 100

      render_click(view, "nudge_subtitle_offset", %{
        "media-file-id" => media_file.id,
        "track-ref" => subtitle.id,
        "delta" => "-100"
      })

      assert Mydia.Subtitles.TrackSettings.offset_ms(media_file.id, subtitle.id) == 0
    end
  end

  describe "rescan_subtitles" do
    setup %{conn: conn} do
      admin = admin_user_fixture()
      %{conn: log_in_user(conn, admin)}
    end

    @srt """
    1
    00:00:01,000 --> 00:00:02,000
    Hello.
    """

    # Mirrors the fixture in test/mydia/subtitles/sidecars_test.exs: a real
    # directory on disk, holding a stand-in video file and a matching sidecar,
    # so Sidecars.reconcile/1 has something real to find.
    defp movie_with_real_directory do
      dir = Path.join(System.tmp_dir!(), "rescan-ui-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      library_path = Mydia.SettingsFixtures.library_path_fixture(%{path: dir})
      media_item = media_item_fixture(%{type: "movie"})

      media_file =
        media_file_fixture(%{
          library_path_id: library_path.id,
          media_item_id: media_item.id,
          relative_path: "Movie.mkv"
        })

      File.write!(Path.join(dir, "Movie.mkv"), "not really a video")

      {media_item, media_file, dir}
    end

    test "adopts a sidecar found on disk and renders its offset form", %{conn: conn} do
      {media_item, media_file, dir} = movie_with_real_directory()
      File.write!(Path.join(dir, "Movie.en.srt"), @srt)

      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      render_click(view, "rescan_subtitles", %{"media-file-id" => media_file.id})
      # An explicit, generous timeout: render_async/1's default comes from
      # :ex_unit, :assert_receive_timeout, and this suite runs many connected
      # LiveView tests back to back, so a task that is normally instant can
      # occasionally lose the race under load. Matches the precedent already
      # set elsewhere in this test tree (e.g. franchise_section_test.exs).
      render_async(view, 5000)

      assert render(view) =~ "Rescan complete: 1 adopted"

      assert [subtitle] = Mydia.Subtitles.list_subtitles(media_file.id)
      assert has_element?(view, "#subtitle-offset-form-#{subtitle.id}")
    end

    # media_file_fixture/1 does not create a directory on disk by default
    # (see test/support/fixtures/settings_fixtures.ex), which is exactly the
    # unreadable-directory case: the realistic failure on a disconnected
    # network mount.
    test "flashes an error rather than crashing when the directory cannot be read", %{
      conn: conn
    } do
      media_item = media_item_fixture(%{type: "movie"})
      media_file = media_file_fixture(%{media_item_id: media_item.id})

      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      render_click(view, "rescan_subtitles", %{"media-file-id" => media_file.id})
      render_async(view, 5000)

      assert render(view) =~ "directory"
    end
  end

  describe "embedded tracks" do
    setup %{conn: conn} do
      admin = admin_user_fixture()
      %{conn: log_in_user(conn, admin)}
    end

    test "renders an embedded stream with the Embedded badge and no delete button", %{
      conn: conn
    } do
      media_item = media_item_fixture(%{type: "movie"})

      media_file =
        media_file_fixture(%{
          media_item_id: media_item.id,
          metadata: %Mydia.Library.Structs.FileMetadata{
            streams: [
              %Mydia.Library.Structs.StreamInfo{
                index: 2,
                type: :subtitle,
                codec: "subrip",
                language: "eng",
                title: "English"
              }
            ]
          }
        })

      {:ok, subtitle} =
        %Mydia.Subtitles.Subtitle{}
        |> Mydia.Subtitles.Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          provider: "sidecar",
          origin: "sidecar",
          subtitle_hash: "embedded-vs-sidecar-hash",
          file_path: "/tmp/embedded-vs-sidecar.srt",
          format: "srt"
        })
        |> Mydia.Repo.insert()

      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      # The embedded track: form present, badge present, no delete button
      # (there is no subtitles row, and so no file, to delete).
      assert has_element?(view, "#subtitle-offset-form-2")
      assert render(view) =~ "Embedded"
      refute has_element?(view, "[phx-click='delete_subtitle'][phx-value-subtitle-id='2']")

      # The sidecar track, alongside it in the same file, does get one.
      assert has_element?(
               view,
               "[phx-click='delete_subtitle'][phx-value-subtitle-id='#{subtitle.id}']"
             )
    end
  end
end
