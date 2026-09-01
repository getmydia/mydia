defmodule MydiaWeb.MediaLive.Show.FileDetailsModalTest do
  # Connected LiveView tests cannot be async under the PostgreSQL sandbox.
  use MydiaWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.Repo

  setup %{conn: conn} do
    {conn, user} = register_and_log_in_user(conn)
    %{conn: conn, user: user}
  end

  setup do
    library_path = library_path_fixture(%{type: "movies"})
    item = media_item_fixture(%{type: "movie", title: "Cinder Lantern"})

    file =
      %MediaFile{}
      |> MediaFile.changeset(%{
        media_item_id: item.id,
        library_path_id: library_path.id,
        relative_path: "Cinder Lantern (2014)/Cinder.Lantern.2014.1080p.mkv",
        size: 1024,
        metadata: %FileMetadata{
          duration: 5400.0,
          container: "matroska",
          width: 1920,
          height: 1080,
          streams: [%StreamInfo{index: 0, type: "video", codec: "h264"}]
        }
      })
      |> Repo.insert!()

    # ExUnit's context already reserves the key :file for the test's own
    # source file, so the setup result uses :media_file instead.
    %{item: item, media_file: file, library_path: library_path}
  end

  test "opens for a file with populated metadata and shows the absolute path", %{
    conn: conn,
    item: item,
    media_file: file,
    library_path: library_path
  } do
    {:ok, view, _html} = live(conn, ~p"/media/#{item.id}")

    html =
      view
      |> element("#version-#{file.id} button[phx-click='show_file_details']")
      |> render_click()

    assert html =~ "Media File Details"
    assert html =~ Path.join(library_path.path, file.relative_path)
    assert html =~ "matroska"
  end
end
