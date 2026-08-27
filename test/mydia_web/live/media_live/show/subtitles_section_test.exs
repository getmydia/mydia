defmodule MydiaWeb.MediaLive.Show.SubtitlesSectionTest do
  # async: false - the "offset control" describe block below opens a connected
  # LiveView (`live/2`), which shares the Postgres sandbox connection with the
  # test process. That only works in non-async mode.
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

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

  describe "subtitles_section/1 TV episodes" do
    # A MediaFile belongs to either media_item_id (movies) or episode_id (TV
    # episodes), never both, so media_item.media_files alone is always empty
    # for a TV show. Episode files live at media_item.episodes[].media_files
    # instead; the section must reach into both.
    test "renders a media file that belongs to an episode, not just the item's own" do
      episode_file = %MediaFile{
        id: "mf-ep-1",
        path: nil,
        relative_path: "Breaking Bad/Season 01/Breaking.Bad.S01E01.mkv",
        library_path: %LibraryPath{path: "/media/tv"},
        resolution: "1080p",
        codec: "h264"
      }

      html =
        render_component(&Components.subtitles_section/1,
          media_item: %{
            media_files: [],
            episodes: [%{media_files: [episode_file]}]
          },
          media_file_subtitle_tracks: %{}
        )

      assert html =~ "Breaking.Bad.S01E01.mkv"
      assert html =~ ~s|phx-value-media-file-id="mf-ep-1"|
    end

    test "still renders nothing for a TV show with no files anywhere" do
      html =
        render_component(&Components.subtitles_section/1,
          media_item: %{media_files: [], episodes: [%{media_files: []}]},
          media_file_subtitle_tracks: %{}
        )

      refute html =~ ~s|id="subtitles-section"|
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

      assert has_element?(view, "#subtitle-offset-form-#{media_file.id}-#{subtitle.id}")

      view
      |> element("#subtitle-offset-form-#{media_file.id}-#{subtitle.id}")
      |> render_change(%{"offset_ms" => "1500"})

      assert Mydia.Subtitles.TrackSettings.offset_ms(media_file.id, subtitle.id) == 1_500
    end

    test "rejects an out-of-range offset without persisting", %{conn: conn} do
      {media_item, media_file, subtitle} = movie_with_sidecar_subtitle("offset-range-hash")

      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      view
      |> element("#subtitle-offset-form-#{media_file.id}-#{subtitle.id}")
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
      assert has_element?(view, "#subtitle-offset-form-#{media_file.id}-#{subtitle.id}")
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
      assert has_element?(view, "#subtitle-offset-form-#{media_file.id}-2")
      assert render(view) =~ "Embedded"
      refute has_element?(view, "[phx-click='delete_subtitle'][phx-value-subtitle-id='2']")

      # The sidecar track, alongside it in the same file, does get one.
      assert has_element?(
               view,
               "[phx-click='delete_subtitle'][phx-value-subtitle-id='#{subtitle.id}']"
             )
    end
  end

  describe "auto-sync" do
    setup %{conn: conn} do
      # The app skips Oban in test (engine: false), so Oban.insert cannot be
      # resolved from the LiveView process. Start an isolated, manual-mode
      # instance so the enqueue lands where all_enqueued/1 sees it. Mirrors
      # test/mydia_web/live/media_live/segment_status_test.exs.
      engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
      start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

      admin = admin_user_fixture()

      media_item = media_item_fixture(%{type: "movie"})

      media_file =
        media_file_fixture(%{
          media_item_id: media_item.id,
          metadata: %Mydia.Library.Structs.FileMetadata{
            streams: [
              %Mydia.Library.Structs.StreamInfo{
                index: 3,
                type: :subtitle,
                codec: "subrip",
                language: "eng",
                title: "English"
              }
            ]
          }
        })

      %{conn: log_in_user(conn, admin), media_item: media_item, media_file: media_file}
    end

    test "the button enqueues exactly one re-sync job",
         %{conn: conn, media_item: media_item, media_file: media_file} do
      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      assert view
             |> element("#resync-subtitle-#{media_file.id}-3")
             |> render_click()

      assert [_job] = all_enqueued(worker: Mydia.Jobs.SubtitleResync)
    end

    test "a low confidence outcome renders as declined with the stepper still usable",
         %{conn: conn, media_item: media_item, media_file: media_file} do
      {:ok, _} =
        Mydia.Subtitles.TrackSettings.record_resync(media_file.id, "3", :low_confidence, 0.09)

      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      assert has_element?(view, "#resync-state-#{media_file.id}-3")
      assert has_element?(view, "#subtitle-offset-form-#{media_file.id}-3")
    end
  end

  describe "TV episode" do
    setup %{conn: conn} do
      admin = admin_user_fixture()
      %{conn: log_in_user(conn, admin)}
    end

    # The full page-mount path: a MediaFile belongs to either media_item_id
    # (movies) or episode_id (TV episodes), never both, so this only renders
    # if the section reaches into media_item.episodes[].media_files instead
    # of media_item.media_files alone.
    test "renders a subtitle track for an episode's media file", %{conn: conn} do
      media_item = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: media_item.id})
      media_file = media_file_fixture(%{episode_id: episode.id})

      {:ok, subtitle} =
        %Mydia.Subtitles.Subtitle{}
        |> Mydia.Subtitles.Subtitle.changeset(%{
          media_file_id: media_file.id,
          language: "en",
          provider: "sidecar",
          origin: "sidecar",
          subtitle_hash: "tv-episode-hash",
          file_path: "/tmp/tv-episode-hash.srt",
          format: "srt"
        })
        |> Mydia.Repo.insert()

      {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

      assert has_element?(view, "#subtitles-section")
      assert has_element?(view, "#subtitle-offset-form-#{media_file.id}-#{subtitle.id}")
    end
  end

  describe "subtitle_track_row/1 DOM id uniqueness" do
    # track_id for an embedded track is the ffprobe stream index, scoped to a
    # single media file -- not a globally unique value. Two files in the same
    # season routinely each have an embedded subtitle at the same index (e.g.
    # both start their streams with index 2), so the row's DOM id has to fold
    # in media_file_id or two rows in the same #subtitles-section collide.
    test "gives two media files' same-index embedded track its own form id" do
      file_a = %MediaFile{
        id: "mf-a",
        relative_path: "Show/Season 01/Show.S01E01.mkv",
        library_path: %LibraryPath{path: "/media/tv"}
      }

      file_b = %MediaFile{
        id: "mf-b",
        relative_path: "Show/Season 01/Show.S01E02.mkv",
        library_path: %LibraryPath{path: "/media/tv"}
      }

      track = %{
        track_id: 2,
        language: "eng",
        title: "English",
        format: "subrip",
        origin: :embedded,
        offset_ms: 0
      }

      html =
        render_component(&Components.subtitles_section/1,
          media_item: %{media_files: [], episodes: [%{media_files: [file_a, file_b]}]},
          media_file_subtitle_tracks: %{"mf-a" => [track], "mf-b" => [track]}
        )

      assert html =~ ~s|id="subtitle-offset-form-mf-a-2"|
      assert html =~ ~s|id="subtitle-offset-form-mf-b-2"|
      # The bug this guards against: without media_file_id folded in, both
      # rows render the exact same id, which is what makes LiveView's DOM
      # patching unpredictable once two files share a section.
      refute html =~ ~s|id="subtitle-offset-form-2"|
    end
  end
end
