defmodule MydiaWeb.MediaLive.Show.SubtitleUploadTest do
  # async: false - live/2 below opens a connected LiveView, which shares the
  # Postgres sandbox connection with the test process. That only works in
  # non-async mode; see subtitle_surface_test.exs for the same rule applied
  # to the sibling manage-modal tests.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Library.MediaFile

  @srt """
  1
  00:00:01,000 --> 00:00:02,000
  Hello.
  """

  setup %{conn: conn} do
    admin = admin_user_fixture()
    %{conn: log_in_user(conn, admin)}
  end

  defp movie_with_media_file(relative_path \\ "Movie.mkv", attrs \\ %{}) do
    dir = Path.join(System.tmp_dir!(), "subtitle-upload-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    library_path = Mydia.SettingsFixtures.library_path_fixture(%{path: dir})
    media_item = media_item_fixture(%{type: "movie"})

    media_file =
      %{
        media_item_id: media_item.id,
        library_path_id: library_path.id,
        relative_path: relative_path
      }
      |> Map.merge(attrs)
      |> media_file_fixture()

    File.write!(Path.join(dir, relative_path), "not really a video")

    {media_item, Mydia.Repo.preload(media_file, :library_path)}
  end

  defp upload_entry(view, content, name) do
    file_input(view, "#subtitle-upload-form", :subtitle, [
      %{
        last_modified: 1_700_000_000_000,
        name: name,
        content: content,
        type: "application/x-subrip"
      }
    ])
  end

  # The panel that used to put an Upload button directly on the page is gone;
  # the manage modal is now the only path to it. Open that first, then click
  # its Upload action, rather than the file row's own button (which only
  # opens the manage modal, not the upload form directly).
  defp open_upload_modal(view, media_file_id) do
    render_click(view, "open_subtitle_manage", %{"media-file-id" => media_file_id})
    view |> element("#subtitle-manage-upload") |> render_click()
  end

  test "uploads an SRT and creates an upload-origin track", %{conn: conn} do
    {media_item, media_file} = movie_with_media_file()

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    open_upload_modal(view, media_file.id)

    upload = upload_entry(view, @srt, "custom.srt")
    render_upload(upload, "custom.srt")

    html =
      view
      |> element("#subtitle-upload-form")
      |> render_submit(%{"language" => "en"})

    assert [subtitle] = Mydia.Subtitles.list_subtitles(media_file.id)
    assert subtitle.origin == "upload"
    assert subtitle.language == "en"
    assert subtitle.format == "srt"
    assert File.exists?(subtitle.file_path)

    # The upload modal closes and, because it was reached through the manage
    # modal (open_upload_modal/2 above), returns there rather than closing
    # outright: return_to_manage is set at open time from whether the manage
    # modal was already open, and with the standalone panel gone the manage
    # modal is the only path to Upload. This is the connected, end-to-end
    # proof that a successful upload surfaces the new track in the manage
    # modal -- previously impossible to write here because the manage modal
    # and the old panel rendered the same track with duplicate DOM ids.
    # SubtitleComponents.subtitle_track_row/1 labels an upload-origin track
    # "Uploaded".
    refute html =~ "subtitle-upload-form"
    assert html =~ "Uploaded"
    assert has_element?(view, "#subtitle-manage-modal")
    assert has_element?(view, "#subtitle-offset-form-#{media_file.id}-#{subtitle.id}")

    on_exit(fn -> File.rm(subtitle.file_path) end)
  end

  test "rejects a file whose content is not a subtitle", %{conn: conn} do
    {media_item, media_file} = movie_with_media_file()

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    open_upload_modal(view, media_file.id)

    upload = upload_entry(view, <<0, 1, 2, 3>>, "fake.srt")
    render_upload(upload, "fake.srt")

    html =
      view
      |> element("#subtitle-upload-form")
      |> render_submit(%{"language" => "en"})

    assert html =~ "not a subtitle"
    assert Mydia.Subtitles.list_subtitles(media_file.id) == []
  end

  test "refuses to overwrite an existing sidecar for the same language", %{conn: conn} do
    {media_item, media_file} = movie_with_media_file()

    existing =
      media_file
      |> MediaFile.absolute_path()
      |> Path.rootname()
      |> Kernel.<>(".en.srt")

    File.write!(existing, @srt)
    on_exit(fn -> File.rm(existing) end)

    {:ok, view, _html} = live(conn, ~p"/media/#{media_item.id}")

    open_upload_modal(view, media_file.id)

    upload = upload_entry(view, @srt, "custom.srt")
    render_upload(upload, "custom.srt")

    html =
      view
      |> element("#subtitle-upload-form")
      |> render_submit(%{"language" => "en"})

    assert html =~ "already a subtitle"
    assert Mydia.Subtitles.list_subtitles(media_file.id) == []
  end

  # See Mydia.Subtitles.UploaderTest for the full matrix of this hazard; this
  # is one end-to-end check that the refusal actually reaches the rendered
  # page through the LiveView wiring, not just the context function.
  test "refuses an upload against a file that does not own the sidecar it would share", %{
    conn: conn
  } do
    dir =
      Path.join(
        System.tmp_dir!(),
        "subtitle-upload-identical-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    library_path = Mydia.SettingsFixtures.library_path_fixture(%{path: dir})

    low_item = media_item_fixture(%{type: "movie"})

    low_file =
      media_file_fixture(%{
        media_item_id: low_item.id,
        library_path_id: library_path.id,
        relative_path: "Movie.mp4",
        resolution: "480p"
      })

    high_item = media_item_fixture(%{type: "movie"})

    high_file =
      media_file_fixture(%{
        media_item_id: high_item.id,
        library_path_id: library_path.id,
        relative_path: "Movie.mkv",
        resolution: "1080p"
      })

    File.write!(Path.join(dir, "Movie.mp4"), "not really a video")
    File.write!(Path.join(dir, "Movie.mkv"), "not really a video either")

    {:ok, view, _html} = live(conn, ~p"/media/#{low_item.id}")

    open_upload_modal(view, low_file.id)

    upload = upload_entry(view, @srt, "custom.srt")
    render_upload(upload, "custom.srt")

    html =
      view
      |> element("#subtitle-upload-form")
      |> render_submit(%{"language" => "en"})

    assert html =~ "Movie.mkv"
    assert File.exists?(Path.join(dir, "Movie.en.srt")) == false
    assert Mydia.Subtitles.list_subtitles(low_file.id) == []
    assert Mydia.Subtitles.list_subtitles(high_file.id) == []
  end
end
