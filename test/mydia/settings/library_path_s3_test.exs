defmodule Mydia.Settings.LibraryPathS3Test do
  use Mydia.DataCase, async: false

  alias Mydia.Settings
  alias Mydia.Settings.LibraryPath

  setup do
    {:ok, _} =
      Settings.create_storage_backend(%{
        name: "media",
        bucket: "b",
        access_key_id: "k",
        secret_access_key: "s"
      })

    :ok
  end

  test "accepts s3://<known backend>/<prefix>" do
    cs = LibraryPath.changeset(%LibraryPath{}, %{path: "s3://media/movies", type: :movies})
    assert cs.valid?
  end

  test "rejects an unknown backend and a malformed s3 path" do
    for path <- ["s3://nope/movies", "s3://"] do
      cs = LibraryPath.changeset(%LibraryPath{}, %{path: path, type: :movies})
      assert errors_on(cs).path
    end
  end

  test "accepts every write feature on S3 libraries" do
    assert {:ok, lp} =
             Mydia.Settings.create_library_path(%{
               path: "s3://media/movies",
               type: "movies",
               auto_organize: true,
               auto_rename: true,
               write_nfo: true,
               default_for_movies: true
             })

    assert lp.auto_organize and lp.auto_rename and lp.write_nfo and lp.default_for_movies
  end

  test "auto_rename defaults to true on S3 libraries too" do
    assert {:ok, lp} =
             Mydia.Settings.create_library_path(%{path: "s3://media/tv", type: "series"})

    assert lp.auto_rename
  end

  describe "changing a library path to an S3 location" do
    setup do
      bypass = Bypass.open()

      {:ok, _} =
        Settings.create_storage_backend(%{
          name: "denied",
          bucket: "locked",
          endpoint: "http://localhost:#{bypass.port}",
          path_style: true,
          access_key_id: "k",
          secret_access_key: "s"
        })

      {:ok, lp} = Settings.create_library_path(%{path: "/tmp/s3-task5-old", type: :movies})
      %{bypass: bypass, library_path: lp}
    end

    test "is refused when the bucket denies access", %{bypass: bypass, library_path: lp} do
      Bypass.expect(bypass, "GET", "/locked", &Plug.Conn.resp(&1, 403, ""))

      assert {:error, cs} = Settings.update_library_path(lp, %{path: "s3://denied/movies"})
      {message, _} = cs.errors[:path]
      assert message =~ "access denied"
    end
  end
end
