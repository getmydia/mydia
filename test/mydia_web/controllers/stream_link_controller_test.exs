defmodule MydiaWeb.StreamLinkControllerTest do
  # async: false because disable_player/0 writes application env.
  use MydiaWeb.ConnCase, async: false

  import Ecto.Query
  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.PlayerHelpers
  import Mydia.SettingsFixtures

  alias Mydia.Library.MediaFile
  alias Mydia.Media.MediaItem
  alias Mydia.Repo
  alias MydiaWeb.StreamLink

  @size 10 * 1024

  setup do
    user = MydiaWeb.AuthHelpers.create_test_user()
    library_path = library_path_fixture()
    File.mkdir_p!(library_path.path)

    name = "Zephyr.Station.2030.#{System.unique_integer([:positive])}.mp4"
    disk_path = Path.join(library_path.path, name)
    File.write!(disk_path, :crypto.strong_rand_bytes(@size))
    on_exit(fn -> File.rm(disk_path) end)

    media_file =
      media_file_fixture(%{library_path_id: library_path.id, relative_path: name})
      |> Repo.preload(:library_path)

    %{user: user, media_file: media_file}
  end

  test "serves the whole file with no Range header", %{conn: conn, user: user, media_file: file} do
    conn = get(conn, StreamLink.path(user.id, file))

    assert conn.status == 200
    assert get_resp_header(conn, "accept-ranges") == ["bytes"]
    assert get_resp_header(conn, "content-length") == ["#{@size}"]
    assert get_resp_header(conn, "cache-control") == ["private, no-store"]
  end

  test "serves a byte range", %{conn: conn, user: user, media_file: file} do
    conn =
      conn
      |> put_req_header("range", "bytes=0-9")
      |> get(StreamLink.path(user.id, file))

    assert conn.status == 206
    assert get_resp_header(conn, "content-range") == ["bytes 0-9/#{@size}"]
    assert get_resp_header(conn, "content-length") == ["10"]
  end

  test "answers HEAD with headers and no body", %{conn: conn, user: user, media_file: file} do
    conn = head(conn, StreamLink.path(user.id, file))

    # Plug.Head rewrites HEAD to GET before the router, and the real server
    # drops the body; the test adapter does not, so assert headers only.
    assert conn.status == 200
    assert get_resp_header(conn, "content-length") == ["#{@size}"]
  end

  test "ignores the filename segment", %{conn: conn, user: user, media_file: file} do
    ["", "stream", token, _name] = String.split(StreamLink.path(user.id, file), "/")

    assert get(conn, "/stream/#{token}/anything.mkv").status == 200
  end

  test "a tampered token is not found", %{conn: conn, user: user, media_file: file} do
    ["", "stream", token, name] = String.split(StreamLink.path(user.id, file), "/")

    assert response(get(conn, "/stream/#{token}x/#{name}"), 404) == "Not found"
  end

  test "a trashed file is not found", %{conn: conn, user: user, media_file: file} do
    Repo.update_all(from(f in MediaFile, where: f.id == ^file.id),
      set: [trashed_at: DateTime.utc_now(:second)]
    )

    assert response(get(conn, StreamLink.path(user.id, file)), 404) == "Not found"
  end

  test "a deleted user's link is not found", %{conn: conn, user: user, media_file: file} do
    path = StreamLink.path(user.id, file)
    Repo.delete!(user)

    assert response(get(conn, path), 404) == "Not found"
  end

  test "a user restricted away from the file is not found", %{conn: conn, media_file: file} do
    Repo.update_all(from(m in MediaItem, where: m.id == ^file.media_item_id),
      set: [category: "movie"]
    )

    restricted = restricted_user_fixture(%{allowed_categories: ["cartoon_movie"]})

    assert response(get(conn, StreamLink.path(restricted.id, file)), 404) == "Not found"
  end

  @tag :capture_log
  test "a file missing on disk is not found", %{conn: conn, user: user, media_file: file} do
    File.rm!(MediaFile.absolute_path(file))

    assert response(get(conn, StreamLink.path(user.id, file)), 404) == "Not found"
  end

  test "works with the player disabled", %{conn: conn, user: user, media_file: file} do
    disable_player()

    assert get(conn, StreamLink.path(user.id, file)).status == 200
  end
end
