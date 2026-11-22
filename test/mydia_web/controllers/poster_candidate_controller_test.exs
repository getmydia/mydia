defmodule MydiaWeb.PosterCandidateControllerTest do
  use MydiaWeb.ConnCase, async: true

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  @jpg <<0xFF, 0xD8, 0xFF, 0xE0, 0::64>>

  setup do
    root = Path.join(System.tmp_dir!(), "poster_candidates_#{System.unique_integer([:positive])}")
    dir = "Copper Lantern (2001)"
    File.mkdir_p!(Path.join(root, dir))
    File.write!(Path.join([root, dir, "film.mkv"]), "video")
    File.write!(Path.join([root, dir, "poster.jpg"]), @jpg)
    File.write!(Path.join([root, dir, "notes.txt"]), "hello")
    on_exit(fn -> File.rm_rf!(root) end)

    lp = library_path_fixture(%{path: root, type: "movies"})
    item = media_item_fixture(%{type: "movie", title: "Copper Lantern"})

    media_file_fixture(%{
      media_item_id: item.id,
      library_path_id: lp.id,
      relative_path: "#{dir}/film.mkv"
    })

    %{item: item, lp: lp, dir: dir}
  end

  defp candidate_path(item, lp, rel),
    do: "/media/#{item.id}/poster-candidates/#{lp.id}/" <> rel

  test "an admin gets a listed candidate's bytes with its content type",
       %{conn: conn, item: item, lp: lp, dir: dir} do
    conn =
      conn
      |> log_in_user(create_admin_user())
      |> get(candidate_path(item, lp, URI.encode(dir) <> "/poster.jpg"))

    assert response(conn, 200) == @jpg
    assert [content_type] = get_resp_header(conn, "content-type")
    assert content_type =~ "image/jpeg"
    assert get_resp_header(conn, "cache-control") == ["private, max-age=60"]
  end

  test "a path that is not a candidate is 404", %{conn: conn, item: item, lp: lp, dir: dir} do
    conn = log_in_user(conn, create_admin_user())

    assert conn |> get(candidate_path(item, lp, URI.encode(dir) <> "/notes.txt")) |> response(404)

    assert conn
           |> get(candidate_path(item, lp, URI.encode(dir) <> "/../../etc/passwd"))
           |> response(404)

    assert conn |> get(candidate_path(item, lp, "poster.jpg")) |> response(404)
  end

  test "an unknown media item is 404", %{conn: conn, lp: lp, dir: dir} do
    conn =
      conn
      |> log_in_user(create_admin_user())
      |> get(
        "/media/#{Ecto.UUID.generate()}/poster-candidates/#{lp.id}/" <>
          URI.encode(dir) <> "/poster.jpg"
      )

    assert response(conn, 404)
  end

  test "a non-admin editor gets the candidate", %{conn: conn, item: item, lp: lp, dir: dir} do
    conn =
      conn
      |> log_in_user(create_test_user(%{role: "user"}))
      |> get(candidate_path(item, lp, URI.encode(dir) <> "/poster.jpg"))

    assert response(conn, 200) == @jpg
  end

  test "a user who may not edit media is 403", %{conn: conn, item: item, lp: lp, dir: dir} do
    conn =
      conn
      |> log_in_user(create_test_user(%{role: "readonly"}))
      |> get(candidate_path(item, lp, URI.encode(dir) <> "/poster.jpg"))

    assert response(conn, 403)
  end

  test "a signed-out request is redirected to log in",
       %{conn: conn, item: item, lp: lp, dir: dir} do
    conn = get(conn, candidate_path(item, lp, URI.encode(dir) <> "/poster.jpg"))

    assert redirected_to(conn) =~ "/auth"
  end
end
